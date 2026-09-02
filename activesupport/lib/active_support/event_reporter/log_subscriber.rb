# :markup: markdown
# frozen_string_literal: true

require "active_support/core_ext/class/attribute"

module ActiveSupport
  class EventReporter
    class LogSubscriber
      include ColorizeLogging

      LOG_LEVELS = [:debug, :info, :error].freeze
      LOG_LEVEL_PREDICATES = { debug: :debug?, info: :info?, error: :error? }.freeze # :nodoc:

      class << self
        def event_log_level(method_name, level)
          self.log_levels = log_levels.merge(method_name.to_s => level).freeze
        end

        def logger
          @logger || default_logger
        end

        def default_logger
          raise NotImplementedError
        end

        attr_writer :logger
        attr_accessor :namespace

        def subscription_filter
          namespace = self.namespace.to_s
          proc do |event|
            name = event[:name]
            if (dot_idx = name.index("."))
              event_namespace = name[0, dot_idx]
              namespace == event_namespace && level_enabled?(name[(dot_idx + 1)..])
            end
          end
        end

        # Whether the configured logger would emit this event at its declared
        # level. Consulted from the subscription filter so events nobody will
        # log are dropped before the reporter builds them. Events with no
        # declared level are always delivered, so a subscriber that handles
        # them in its own +emit+ keeps receiving them.
        def level_enabled?(event_method)
          severity_enabled?(log_levels[event_method])
        end

        def wants_source_location? # :nodoc:
          false
        end

        # Answers whether the logger would accept the given severity. A
        # logger that cannot answer, or no logger at all, leaves the event
        # in: the subscriber's own +emit+ then raises inside the reporter's
        # error handling, exactly where it did before the filter asked.
        def severity_enabled?(level) # :nodoc:
          predicate = LOG_LEVEL_PREDICATES[level]
          return true unless predicate

          logger.public_send(predicate)
        rescue StandardError
          true
        end
      end

      class_attribute :log_levels, default: {}.freeze # :nodoc:

      def emit(event)
        return unless logger
        name = event[:name]
        event_method = name[name.index(".") + 1, name.length]

        public_send(event_method, event) if log_level_satisfied?(event_method)
      end

      def logger
        self.class.logger
      end

      private
        def namespace
          self.class.namespace
        end

        def log_level_satisfied?(event_method)
          event_log_level = log_levels[event_method]
          return false unless LOG_LEVELS.include?(event_log_level)

          logger.public_send("#{event_log_level}?")
        end
    end
  end
end
