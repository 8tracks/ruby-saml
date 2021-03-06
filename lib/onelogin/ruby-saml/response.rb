require "xml_security"
require "time"
require "nokogiri"

# Only supports SAML 2.0
module Onelogin
  module Saml

    class Response
      ASSERTION = "urn:oasis:names:tc:SAML:2.0:assertion"
      PROTOCOL  = "urn:oasis:names:tc:SAML:2.0:protocol"
      DSIG      = "http://www.w3.org/2000/09/xmldsig#"

      # TODO: This should probably be ctor initialized too... WDYT?
      attr_accessor :settings

      attr_reader :options
      attr_reader :response
      attr_reader :document
      attr_reader :validation_errors

      def initialize(response, options = {})
        raise ArgumentError.new("Response cannot be nil") if response.nil?
        @options  = options
        @response = (response =~ /^</) ? response : Base64.decode64(response)
        @document = XMLSecurity::SignedDocument.new(@response)
      end

      def is_valid?
        validate
      end

      def clear_validation_errors!
        @validation_errors.clear
      end

      def validate!
        validate(false)
      end

      def xbox_attributes
        return @xbox_attributes if @xbox_attributes
        attrs = attributes

        @xbox_attributes = {
          :pxuid     => attrs["http://schemas.microsoft.com/xbox/2011/07/claims/user/pxuid"],
          :version   => attrs["http://schemas.microsoft.com/xbox/2011/07/claims/title/version"],
          :age_group => attrs["http://schemas.microsoft.com/xbox/2011/07/claims/user/agegroup"],
          :gamer_tag => attrs["http://schemas.microsoft.com/xbox/2011/07/claims/user/gamertag"],
          :tier      => attrs["http://schemas.microsoft.com/xbox/2011/07/claims/user/tier"]
        }
      end

      # The value of the user identifier as designated by the initialization request response
      def name_id
        @name_id ||= begin
          node = xpath_first_from_signed_assertion('/a:Subject/a:NameID')
          node.nil? ? nil : node.text
        end
      end

      def sessionindex
        @sessionindex ||= begin
          node = xpath_first_from_signed_assertion('/a:AuthnStatement')
          node.nil? ? nil : node.attributes['SessionIndex']
        end
      end

      # A hash of alle the attributes with the response. Assuming there is only one value for each key
      def attributes
        @attr_statements ||= begin
          result = {}

          stmt_element = xpath_first_from_signed_assertion('/a:AttributeStatement')
          return {} if stmt_element.nil?

          stmt_element.elements.each do |attr_element|
            name  = attr_element.attributes["Name"]
            value = attr_element.elements.first.text

            result[name] = value
          end

          result.keys.each do |key|
            result[key.intern] = result[key]
          end

          result
        end
      end

      # When this user session should expire at latest
      def session_expires_at
        @expires_at ||= begin
          node = xpath_first_from_signed_assertion('/a:AuthnStatement')
          parse_time(node, "SessionNotOnOrAfter")
        end
      end

      # Checks the status of the response for a "Success" code
      def success?
        @status_code ||= begin
          node = REXML::XPath.first(document, "/p:Response/p:Status/p:StatusCode", { "p" => PROTOCOL, "a" => ASSERTION })
          node.attributes["Value"] == "urn:oasis:names:tc:SAML:2.0:status:Success"
        end
      end

      # Conditions (if any) for the assertion to run
      def conditions
        @conditions ||= xpath_first_from_signed_assertion('/a:Conditions')
      end

      def issuer
        @issuer ||= begin
          node = REXML::XPath.first(document, "/a:Issuer", { "p" => PROTOCOL, "a" => ASSERTION })
          node ||= xpath_first_from_signed_assertion('/a:Issuer')
          node.nil? ? nil : node.text
        end
      end



      def validate(options={})
        if !options[:skip_structure]
          unless validate_structure
            return false
          end
        end

        begin
          document.validate_digests
        rescue Onelogin::Saml::ValidationError => ex
          add_validation_error(:invalid_digests, ex.message)
          return false
        end

        begin
          document.validate_signature(Base64.encode64(settings.idp_cert))
        rescue Onelogin::Saml::ValidationError => ex
          add_validation_error(:invalid_signature, ex.message)
          return false
        end

        if validate_conditions
          return true
        else
          return false
        end
      end



      private

      def add_validation_error(error_type, error_message)
        @validation_errors ||= []
        @validation_errors << [ error_type, error_message ]
      end



      def validate_structure
        Dir.chdir(File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'schemas'))) do
          @schema = Nokogiri::XML::Schema(IO.read('saml20protocol_schema.xsd'))
          @xml = Nokogiri::XML(self.document.to_s)
        end

        @schema.validate(@xml).map do |error|
          add_validation_error(:invalid_structure, "#{error.message}\n\n#{@xml.to_s}")
          return false
        end
      end

      # def validate_response_state
      #   if response.empty?
      #     add_validation_error("Blank response")
      #     return false
      #   end

      #   if settings.nil?
      #     add_validation_error("No settings")
      #     return false
      #   end

      #   if settings.idp_cert_fingerprint.nil? && settings.idp_cert.nil?
      #     add_validation_error("No fingerprint or certificate on settings")
      #     return false
      #   end

      #   true
      # end

      def xpath_first_from_signed_assertion(subelt=nil)
        node = REXML::XPath.first(document, "/a:Assertion[@ID='#{document.signed_element_id}']#{subelt}", { "p" => PROTOCOL, "a" => ASSERTION })

        # node = REXML::XPath.first(document, "/p:Response/a:Assertion[@ID='#{document.signed_element_id}']#{subelt}", { "p" => PROTOCOL, "a" => ASSERTION })
        # node ||= REXML::XPath.first(document, "/p:Response[@ID='#{document.signed_element_id}']/a:Assertion#{subelt}", { "p" => PROTOCOL, "a" => ASSERTION })
        node
      end

      def get_fingerprint
        if settings.idp_cert
          cert = OpenSSL::X509::Certificate.new(settings.idp_cert)
          Digest::SHA1.hexdigest(cert.to_der).upcase.scan(/../).join(":")
        else
          settings.idp_cert_fingerprint
        end
      end

      def validate_conditions
        return true if conditions.nil?
        return true if options[:skip_conditions]

        if (not_before = parse_time(conditions, "NotBefore"))
          if Time.now.utc < not_before
            add_validation_error(:invalid_condition, "Current time is earlier than NotBefore condition")
            return false
          end
        end

        if (not_on_or_after = parse_time(conditions, "NotOnOrAfter"))
          if Time.now.utc >= not_on_or_after
            add_validation_error(:invalid_condition, "Current time is on or after NotOnOrAfter condition")
            return false
          end
        end

        true
      end

      def parse_time(node, attribute)
        if node && node.attributes[attribute]
          Time.parse(node.attributes[attribute])
        end
      end
    end
  end
end
