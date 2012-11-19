require 'net/http'
require 'json'
require 'uri'

module IntercomRails
  class ImportError < StandardError; end
  class IntercomAPIError < StandardError; end

  class Import

    def self.bulk_create_api_endpoint
      host = (ENV['INTERCOM_RAILS_DEV'] ? "http://intercom.dev" : "https://api.intercom.io")
      URI.parse(host + "api/v1/users/bulk_create")
    end

    def self.run(*args)
      new(*args).run
    end

    attr_reader :uri, :http
    attr_accessor :failed, :total_sent

    def initialize(options = {})
      @uri = Import.bulk_create_api_endpoint
      @http = Net::HTTP.new(@uri.host, @uri.port)
      @failed = []
      @total_sent = 0

      @status_enabled = !!options[:status_enabled]

      if uri.scheme == 'https'
        http.use_ssl = true 
        http.ca_file = File.join(File.dirname(__FILE__), '../data/ca_cert.pem')
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      end
    end

    def assert_runnable
      raise ImportError, "You can only import your users from your production environment" unless Rails.env.production?
      raise ImportError, "We couldn't find your user class, please set one in config/initializers/intercom_rails.rb" unless user_klass.present?
      raise ImportError, "Only ActiveRecord models are supported" unless (user_klass < ActiveRecord::Base)
      raise ImportError, "Please add an Intercom API Key to config/initializers/intercom.rb" unless IntercomRails.config.api_key.present?
    end

    def run
      assert_runnable

      batches do |batch, number_in_batch|
        failures = send_users(batch)['failed']
        self.failed += failures

        if status_enabled?
          print ('.' * (number_in_batch - failures.count))
          print ('F' * failures.count)
        end
      end

      self
    end

    def total_failed
      self.failed.count
    end

    private
    MAX_BATCH_SIZE = 100
    def batches
      batch = []

      user_klass.find_each(:batch_size => 100) do |user|
        user = user_for_wire(user)
        batch << user unless user.nil?

        if(batch.count >= MAX_BATCH_SIZE)
          yield(prepare_batch(batch), batch.count)
          batch = []
        end
      end

      yield(prepare_batch(batch), batch.count) if batch.present?
    end

    def prepare_batch(batch)
      self.total_sent += batch.count
      {:users => batch}.to_json
    end

    def user_for_wire(user)
      wired = {}.tap do |h|
        h[:user_id] = user.id if user.respond_to?(:id) && user.id.present?
        h[:email] = user.email if user.respond_to?(:email) && user.email.present?
        h[:name] = user.name if user.respond_to?(:name) && user.name.present?
      end

      (wired[:user_id] || wired[:email]) ? wired : nil
    end

    def user_klass
      if IntercomRails.config.user_model.present?
        IntercomRails.config.user_model.call
      else
        User if defined?(User)
      end
    end

    def send_users(users)
      request = Net::HTTP::Post.new(uri.request_uri) 
      request.basic_auth(IntercomRails.config.app_id, IntercomRails.config.api_key)
      request["Content-Type"] = "application/json"
      request.body = users 

      response = perform_request(request)
      JSON.parse(response.body)
    end

    MAX_REQUEST_ATTEMPTS = 3
    def perform_request(request, attempts = 0, error = {})
      if (attempts > 0) && (attempts < MAX_REQUEST_ATTEMPTS)
        sleep(0.5) 
      elsif error.present?
        raise error[:exception] if error[:exception]
        raise exception_for_failed_response(error[:failed_response])
      end

      response = http.request(request)

      return response if successful_response?(response)
      perform_request(request, attempts + 1, :failed_response => response)
    rescue Timeout::Error, Errno::ECONNREFUSED => e
      perform_request(request, attempts + 1, :exception => e)
    end

    def successful_response?(response)
      raise ImportError, "App ID or API Key are incorrect, please check them in config/initializers/intercom.rb" if response.code == '403'
      ['200', '201'].include?(response.code)
    end

    def exception_for_failed_response(response)
      code = response.code
      IntercomAPIError.new("The Intercom API request failed with the code: #{code}, after #{MAX_REQUEST_ATTEMPTS} attempts.")
    end

    def status_enabled?
      @status_enabled
    end

  end
end
