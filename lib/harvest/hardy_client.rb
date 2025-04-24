require 'delegate'

module Harvest
  class HardyClient < SimpleDelegator
    def initialize(client, max_retries)
      super(client)
      @client = client
      @max_retries = max_retries

      define_delegated_methods(@client)
    end

    private

    def define_delegated_methods(target)
      (target.public_methods - Object.public_instance_methods).each do |method_name|
        define_singleton_method(method_name) do |*args, **kwargs, &block|
          wrap_collection do
            target.public_send(method_name, *args, **kwargs, &block)
          end
        end
      end
    end

    def wrap_collection
      collection = yield
      HardyCollection.new(collection, @client, @max_retries)
    end

    class HardyCollection < SimpleDelegator
      def initialize(collection, client, max_retries)
        super(collection)
        @collection = collection
        @client = client
        @max_retries = max_retries

        define_delegated_methods(@collection)
      end

      private

      def define_delegated_methods(target)
        (target.public_methods - Object.public_instance_methods).each do |method_name|
          define_singleton_method(method_name) do |*args, **kwargs, &block|
            retry_rate_limits do
              target.public_send(method_name, *args, **kwargs, &block)
            end
          end
        end
      end

      def retry_rate_limits
        retries = 0

        begin
          yield
        rescue Harvest::RateLimited => e
          sleep(retry_after_seconds(e))
          retry
        rescue Harvest::Unavailable, Harvest::InformHarvest => e
          if (retries += 1) <= @max_retries
            sleep(16) if @client.account.rate_limit_status.over_limit?
            retry
          else
            raise e
          end
        rescue Net::HTTPError, Net::HTTPFatalError => e
          retry if (retries += 1) <= @max_retries
          raise e
        rescue Errno::ECONNRESET => e
          retry if (retries += 1) <= @max_retries
          raise e
        end
      end

      def retry_after_seconds(error)
        retry_after = error.response.headers["retry-after"]
        retry_after ? retry_after.to_i : 16
      end
    end
  end
end
