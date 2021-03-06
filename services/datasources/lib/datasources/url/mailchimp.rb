# encoding: utf-8

require 'typhoeus'
require 'json'
require 'gibbon'
require 'addressable/uri'
require_relative '../base_oauth'

module CartoDB
  module Datasources
    module Url
      # Note:
      # - MailChimp access tokens don't expire, no need to handle that logic
      class MailChimp < BaseOAuth

        # Required for all datasources
        DATASOURCE_NAME = 'mailchimp'

        AUTHORIZE_URI = 'https://login.mailchimp.com/oauth2/authorize?response_type=code&client_id=%s&redirect_uri=%s'
        ACCESS_TOKEN_URI = 'https://login.mailchimp.com/oauth2/token'
        MAILCHIMP_METADATA_URI = 'https://login.mailchimp.com/oauth2/metadata'

        API_TIMEOUT_SECS = 60

        # Constructor
        # @param config Array
        # [
        #  'api_key'
        #  'timeout_minutes'
        # ]
        # @param user User
        # @throws UninitializedError
        # @throws MissingConfigurationError
        def initialize(config, user)
          super

          raise UninitializedError.new('missing user instance', DATASOURCE_NAME) if user.nil?
          raise MissingConfigurationError.new('missing app_key', DATASOURCE_NAME) unless config.include?('app_key')
          raise MissingConfigurationError.new('missing app_secret', DATASOURCE_NAME) unless config.include?('app_secret')
          raise MissingConfigurationError.new('callback_url'. DATASOURCE_NAME) unless config.include?('callback_url')

          @user = user
          @app_key = config.fetch('app_key')
          @app_secret = config.fetch('app_secret')

          placeholder = CALLBACK_STATE_DATA_PLACEHOLDER.sub('user', @user.username).sub('service', DATASOURCE_NAME)
          @callback_url = "#{config.fetch('callback_url')}?state=#{placeholder}"

          Gibbon::API.timeout = API_TIMEOUT_SECS
          Gibbon::API.throws_exceptions = true
          Gibbon::Export.timeout = API_TIMEOUT_SECS
          Gibbon::Export.throws_exceptions = false

          @access_token = nil
          @api_client = nil
        end

        # Factory method
        # @param config : {}
        # @param user : User
        # @return CartoDB::Datasources::Url::MailChimpLists
        def self.get_new(config, user)
          return new(config, user)
        end

        # If will provide a url to download the resource, or requires calling get_resource()
        # @return bool
        def providers_download_url?
          false
        end

        # Return the url to be displayed or sent the user to to authenticate and get authorization code
        # @param use_callback_flow : bool
        # @return string : URL to navigate to for the authorization flow
        # @throws ExternalServiceError
        def get_auth_url(use_callback_flow=true)
          if use_callback_flow
            AUTHORIZE_URI % [@app_key, Addressable::URI.encode(@callback_url)]
          else
            raise ExternalServiceError.new("This datasource doesn't allows non-callback flows", DATASOURCE_NAME)
          end
        end

        # Validate authorization code and store token
        # @param auth_code : string
        # @return string : Access token
        # @throws ExternalServiceError
        def validate_auth_code(auth_code)
          raise ExternalServiceError.new("This datasource doesn't allows non-callback flows", DATASOURCE_NAME)
        end

        # Validates the authorization callback
        # @param params : mixed
        # @throws AuthError
        def validate_callback(params)
          code = params.fetch('code')
          if code.nil? || code == ''
            raise "Empty callback code"
          end

          token_call_params = {
            grant_type: 'authorization_code',
            client_id: @app_key,
            client_secret: @app_secret,
            code: code,
            redirect_uri: @callback_url
          }

          token_response = Typhoeus.post(ACCESS_TOKEN_URI, http_options(token_call_params, :post))
          unless token_response.code == 200
            raise "Bad token response: #{token_response.body.inspect} (#{token_response.code})"
          end
          token_data = ::JSON.parse(token_response.body)

          partial_access_token = token_data['access_token']

          # Afterwards, must do another call to metadata endpoint to retrieve API details
          # @see https://apidocs.mailchimp.com/oauth2/
          metadata_response = Typhoeus.get(MAILCHIMP_METADATA_URI,http_options({}, :get, {
                                             'Authorization' => "OAuth #{partial_access_token}"}))
          unless metadata_response.code == 200
            raise "Bad metadata response: #{metadata_response.body.inspect} (#{metadata_response.code})"
          end
          metadata_data = ::JSON.parse(metadata_response.body)

          # This specially formed token behaves as an API Key for client calls using API
          @access_token = "#{partial_access_token}-#{metadata_data['dc']}"
        rescue => ex
          raise AuthError.new("validate_callback(#{params.inspect}): #{ex.message}", DATASOURCE_NAME)
        end

        # Set the token
        # @param token string
        # @throws TokenExpiredOrInvalidError
        def token=(token)
          @access_token = token
          @api_client = Gibbon::API.new(@access_token)
        rescue Gibbon::MailChimpError => exception
          raise TokenExpiredOrInvalidError.new("token=() : #{exception.message} (API code: #{exception.code})",
                                               DATASOURCE_NAME)
        rescue => exception
          raise TokenExpiredOrInvalidError.new("token=() : #{exception.inspect}", DATASOURCE_NAME)
        end

        # Retrieve set token
        # @return string | nil
        def token
          @access_token
        end

        # Perform the listing and return results
        # @param filter Array : (Optional) filter to specify which resources to retrieve. Leave empty for all supported.
        # @return [ { :id, :title, :url, :service } ]
        # @throws UninitializedError
        # @throws DataDownloadError
        def get_resources_list(filter=[])
          raise UninitializedError.new('No API client instantiated', DATASOURCE_NAME) unless @api_client.present?

          all_results = []
          offset = 0
          limit = 100
          total = nil

          begin
            response = @api_client.lists.list({
                                                start: offset,
                                                limit: limit
                                              })
            errors = response.fetch('errors', [])
            unless errors.empty?
              raise DataDownloadError.new("get_resources_list(): #{errors.inspect}", DATASOURCE_NAME)
            end

            total = response.fetch('total', 0).to_i if total.nil?

            response_data = response.fetch('data', [])
            response_data.each do |item|
              all_results.push(format_item_data(item))
            end

            offset += limit
          end while offset < total

          all_results
        rescue Gibbon::MailChimpError => exception
          raise DataDownloadError.new("get_resources_list(): #{exception.message} (API code: #{exception.code}",
                                      DATASOURCE_NAME)
        rescue => exception
          raise DataDownloadError.new("get_resources_list(): #{exception.inspect}", DATASOURCE_NAME)
        end

        # Retrieves a resource and returns its contents
        # @param id string
        # @return mixed
        # @throws UninitializedError
        # @throws DataDownloadError
        def get_resource(id)
          raise UninitializedError.new('No API client instantiated', DATASOURCE_NAME) unless @api_client.present?

          contents = ''

          export_api = @api_client.get_exporter

          content_iterator = export_api.list({id: id})
          content_iterator.each { |line|
            contents << streamed_json_to_csv(line)
          }

          contents
        rescue Gibbon::MailChimpError => exception
          raise DataDownloadError.new("get_resource(): #{exception.message} (API code: #{exception.code}",
                                      DATASOURCE_NAME)
        rescue => exception
          raise DataDownloadError.new("get_resource(): #{exception.inspect}", DATASOURCE_NAME)
        end

        # @param id string
        # @return Hash
        # @throws UninitializedError
        # @throws DataDownloadError
        def get_resource_metadata(id)
          raise UninitializedError.new('No API client instantiated', DATASOURCE_NAME) unless @api_client.present?

          item_data = {}

          # No metadata call at API, so just retrieve same info but from specific list id
          response = @api_client.lists.list({ filters: { list_id: id } })
          errors = response.fetch('errors', [])
          unless errors.empty?
            raise DataDownloadError.new("get_resources_list(): #{errors.inspect}", DATASOURCE_NAME)
          end
          response_data = response.fetch('data', [])

          response_data.each do |item|
            if item.fetch('id') == id
              item_data = format_item_data(item)
            end
          end

          item_data
        rescue Gibbon::MailChimpError => exception
          raise DataDownloadError.new("get_resource_metadata(): #{exception.message} (API code: #{exception.code}",
                                      DATASOURCE_NAME)
        rescue => exception
          raise DataDownloadError.new("get_resource_metadata(): #{exception.inspect}", DATASOURCE_NAME)
        end

        # Retrieves current filters
        # @return {}
        def filter
          []
        end

        # Sets current filters
        # @param filter_data {}
        def filter=(filter_data=[])
        end

        # Just return datasource name
        # @return string
        def to_s
          DATASOURCE_NAME
        end

        # If this datasource accepts a data import instance
        # @return Boolean
        def persists_state_via_data_import?
          false
        end

        # Stores the data import item instance to use/manipulate it
        # @param value DataImport
        def data_import_item=(value)
          nil
        end

        # Checks if token is still valid or has been revoked
        # @return bool
        # @throws AuthError
        def token_valid?
          raise UninitializedError.new('No API client instantiated', DATASOURCE_NAME) unless @api_client.present?

          # Any call would do, we just want to see if communicates or refuses the token
          # This call is available to all roles
          response = @api_client.users.profile
          # 'errors' only appears in failure scenarios, while 'username' only if went ok
          response.fetch('errors', nil).nil? && !response.fetch('username', nil).nil?
        rescue
          false
        end

        # Revokes current set token
        def revoke_token
          # not supported
        end

        # Sets an error reporting component
        # @param component mixed
        def report_component=(component)
          nil
        end

        private

        def http_options(params={}, method=:get, extra_headers={})
          {
            method:           method,
            params:           method == :get ? params : {},
            body:             method == :post ? params : {},
            followlocation:   true,
            ssl_verifypeer:   false,
            headers:          {
                                'Accept' => 'application/json'
                              }.merge(extra_headers),
            ssl_verifyhost:   0,
            timeout:          60
          }
        end

        # Formats all data to comply with our desired format
        # @param item_data Hash : Single item returned from MailChimp API
        # @return { :id, :title, :url, :service, :size }
        def format_item_data(item_data)
          filename = item_data.fetch('name').gsub(' ', '_')
          member_count = item_data.fetch('stats').fetch('member_count')
          {
            id:       item_data.fetch('id'),
            title:    "#{item_data.fetch('name')}",
            filename: "#{filename}.csv",
            service:  DATASOURCE_NAME,
            checksum: '',
            member_count: member_count,
            size:     0
          }
        end

        # @see https://apidocs.mailchimp.com/export/1.0/#overview_description
        def streamed_json_to_csv(contents='[]')
          contents = ::JSON.parse(contents)
          contents.each_with_index { |field, index|
            contents[index] = "\"#{field.to_s.gsub("\n", ' ').gsub('"', '""')}\""
          }
          data = contents.join(',')
          data << "\n"
        end

      end
    end
  end
end
