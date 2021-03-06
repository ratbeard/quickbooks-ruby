module Quickbooks
  module Service
    class BaseService
      include Quickbooks::Util::Logging
      include ServiceCrud

      attr_accessor :company_id
      attr_accessor :oauth
      attr_reader :base_uri
      attr_reader :last_response_body
      attr_reader :last_response_xml

      XML_NS = %{xmlns="http://schema.intuit.com/finance/v3"}
      HTTP_CONTENT_TYPE = 'application/xml'
      HTTP_ACCEPT = 'application/xml'
      HTTP_ACCEPT_ENCODING = 'gzip, deflate'
      BASE_DOMAIN = 'quickbooks.api.intuit.com'
      SANDBOX_DOMAIN = 'sandbox-quickbooks.api.intuit.com'

      def initialize(attributes = {})
        domain = Quickbooks.sandbox_mode ? SANDBOX_DOMAIN : BASE_DOMAIN
        @base_uri = "https://#{domain}/v3/company"
        attributes.each {|key, value| public_send("#{key}=", value) }
      end

      def access_token=(token)
        @oauth = token
      end

      def company_id=(company_id)
        @company_id = company_id
      end

      # realm & company are synonymous
      def realm_id=(company_id)
        @company_id = company_id
      end

      def url_for_resource(resource)
        "#{url_for_base}/#{resource}"
      end

      def url_for_base
        raise MissingRealmError.new unless @company_id
        "#{@base_uri}/#{@company_id}"
      end

      def default_model_query
        "SELECT * FROM #{self.class.name.split("::").last}"
      end

      def url_for_query(query = nil, start_position = 1, max_results = 20)
        query ||= default_model_query
        query = "#{query} STARTPOSITION #{start_position} MAXRESULTS #{max_results}"

        "#{url_for_base}/query?query=#{URI.encode_www_form_component(query)}"
      end

      private

      def parse_xml(xml)
        @last_response_xml = Nokogiri::XML(xml)
      end

      def valid_xml_document(xml)
        %Q{<?xml version="1.0" encoding="utf-8"?>\n#{xml.strip}}
      end

      # A single object response is the same as a collection response except
      # it just has a single main element
      def fetch_object(model, url, params = {})
        raise ArgumentError, "missing model to instantiate" if model.nil?
        response = do_http_get(url, params)
        collection = parse_collection(response, model)
        if collection.is_a?(Quickbooks::Collection)
          collection.entries.first
        else
          nil
        end
      end

      def fetch_collection(query, model, options = {})
        page = options.fetch(:page, 1)
        per_page = options.fetch(:per_page, 20)

        start_position = ((page - 1) * per_page) + 1 # page=2, per_page=10 then we want to start at 11
        max_results = per_page

        response = do_http_get(url_for_query(query, start_position, max_results))

        parse_collection(response, model)
      end

      def parse_collection(response, model)
        if response
          collection = Quickbooks::Collection.new
          xml = @last_response_xml
          begin
            results = []

            query_response = xml.xpath("//xmlns:IntuitResponse/xmlns:QueryResponse")[0]
            if query_response

              start_pos_attr = query_response.attributes['startPosition']
              if start_pos_attr
                collection.start_position = start_pos_attr.value.to_i
              end

              max_results_attr = query_response.attributes['maxResults']
              if max_results_attr
                collection.max_results = max_results_attr.value.to_i
              end

              total_count_attr = query_response.attributes['totalCount']
              if total_count_attr
                collection.total_count = total_count_attr.value.to_i
              end
            end

            path_to_nodes = "//xmlns:IntuitResponse//xmlns:#{model::XML_NODE}"
            collection.count = xml.xpath(path_to_nodes).count
            if collection.count > 0
              xml.xpath(path_to_nodes).each do |xa|
                results << model.from_xml(xa)
              end
            end

            collection.entries = results
          rescue => ex
            raise Quickbooks::IntuitRequestException.new("Error parsing XML: #{ex.message}")
          end
          collection
        else
          nil
        end
      end

      # Given an IntuitResponse which is expected to wrap a single
      # Entity node, e.g.
      # <IntuitResponse xmlns="http://schema.intuit.com/finance/v3" time="2013-11-16T10:26:42.762-08:00">
      #   <Customer domain="QBO" sparse="false">
      #     <Id>1</Id>
      #     ...
      #   </Customer>
      # </IntuitResponse>
      def parse_singular_entity_response(model, xml, node_xpath_prefix = nil)
        xmldoc = Nokogiri(xml)
        prefix = node_xpath_prefix || model::XML_NODE
        xmldoc.xpath("//xmlns:IntuitResponse/xmlns:#{prefix}")[0]
      end

      # A successful delete request returns a XML packet like:
      # <IntuitResponse xmlns="http://schema.intuit.com/finance/v3" time="2013-04-23T08:30:33.626-07:00">
      #   <Payment domain="QBO" status="Deleted">
      #   <Id>8748</Id>
      #   </Payment>
      # </IntuitResponse>
      def parse_singular_entity_response_for_delete(model, xml)
        xmldoc = Nokogiri(xml)
        xmldoc.xpath("//xmlns:IntuitResponse/xmlns:#{model::XML_NODE}[@status='Deleted']").length == 1
      end

      def do_http_post(url, body = "", params = {}, headers = {}) # throws IntuitRequestException
        url = add_query_string_to_url(url, params)
        do_http(:post, url, body, headers)
      end

      def do_http_get(url, params = {}, headers = {}) # throws IntuitRequestException
        url = add_query_string_to_url(url, params)
        do_http(:get, url, {}, headers)
      end

      def do_http_file_upload(uploadIO, url, metadata = nil)
        headers = {
          'Content-Type' => 'multipart/form-data'
        }
        body = {}
        body['file_content_0'] = uploadIO

        if metadata
          standalone_prefix = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          meta_data_xml = "#{standalone_prefix}\n#{metadata.to_xml_ns.to_s}"
          param_part = UploadIO.new(StringIO.new(meta_data_xml), "application/xml")
          body['file_metadata_0'] = param_part
        end

        do_http(:upload, url, body, headers)
      end

      def do_http(method, url, body, headers) # throws IntuitRequestException
        if @oauth.nil?
          raise "OAuth client has not been initialized. Initialize with setter access_token="
        end
        unless headers.has_key?('Content-Type')
          headers['Content-Type'] = HTTP_CONTENT_TYPE
        end
        unless headers.has_key?('Accept')
          headers['Accept'] = HTTP_ACCEPT
        end
        unless headers.has_key?('Accept-Encoding')
          headers['Accept-Encoding'] = HTTP_ACCEPT_ENCODING
        end

        log "------ QUICKBOOKS-RUBY REQUEST ------"
        log "METHOD = #{method}"
        log "RESOURCE = #{url}"
        log "REQUEST BODY:"
        log(log_xml(body))
        log "REQUEST HEADERS = #{headers.inspect}"

        response = case method
          when :get
            @oauth.get(url, headers)
          when :post
            @oauth.post(url, body, headers)
          when :upload
            @oauth.post_with_multipart(url, body, headers)
          else
            raise "Do not know how to perform that HTTP operation"
          end
        check_response(response, :request_xml => body)
      end

      def add_query_string_to_url(url, params)
        if params.is_a?(Hash) && !params.empty?
          url + "?" + params.collect { |k| "#{k.first}=#{k.last}" }.join("&")
        else
          url
        end
      end

      def check_response(response, options = {})
        log "------ QUICKBOOKS-RUBY RESPONSE ------"
        log "RESPONSE CODE = #{response.code}"
        log "RESPONSE BODY:"
        log(log_xml(response.plain_body))
        parse_xml(response.plain_body)
        status = response.code.to_i
        case status
        when 200
          # even HTTP 200 can contain an error, so we always have to peek for an Error
          if response_is_error?
            parse_and_raise_exception(options)
          else
            response
          end
        when 302
          raise "Unhandled HTTP Redirect"
        when 401
          raise Quickbooks::AuthorizationFailure
        when 403
          raise Quickbooks::Forbidden
        when 400, 500
          parse_and_raise_exception(options)
        when 503, 504
          raise Quickbooks::ServiceUnavailable
        else
          raise "HTTP Error Code: #{status}, Msg: #{response.plain_body}"
        end
      end

      def parse_and_raise_exception(options = {})
        err = parse_intuit_error
        ex = Quickbooks::IntuitRequestException.new("#{err[:message]}:\n\t#{err[:detail]}")
        ex.code = err[:code]
        ex.detail = err[:detail]
        ex.type = err[:type]
        ex.request_xml = options[:request_xml]
        raise ex
      end

      def response_is_error?
        @last_response_xml.xpath("//xmlns:IntuitResponse/xmlns:Fault")[0] != nil
      rescue Nokogiri::XML::XPath::SyntaxError => exception
        true
      end

      def parse_intuit_error
        error = {:message => "", :detail => "", :type => nil, :code => 0}
        fault = @last_response_xml.xpath("//xmlns:IntuitResponse/xmlns:Fault")[0]
        if fault
          error[:type] = fault.attributes['type'].value

          error_element = fault.xpath("//xmlns:Error")[0]
          if error_element
            code_attr = error_element.attributes['code']
            if code_attr
              error[:code] = code_attr.value
            end
            element_attr = error_element.attributes['element']
            if code_attr
              error[:element] = code_attr.value
            end
            error[:message] = error_element.xpath("//xmlns:Message").text
            error[:detail] = error_element.xpath("//xmlns:Detail").text
          end
        end

        error
      rescue Nokogiri::XML::XPath::SyntaxError => exception
        error[:detail] = @last_response_xml.to_s

        error
      end

    end
  end
end
