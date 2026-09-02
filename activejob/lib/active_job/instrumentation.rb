# frozen_string_literal: true

module ActiveJob
  class << self
    private
      def instrument_enqueue_all(queue_adapter, jobs)
        payload = { adapter: queue_adapter, jobs: jobs }
        ActiveSupport::Notifications.instrument("enqueue_all.active_job", payload) do
          result = yield payload
          payload[:enqueued_count] = result
          result
        end
      end
  end

  module Instrumentation # :nodoc:
    extend ActiveSupport::Concern

    EVENT_NAMES = %i[ enqueue enqueue_at perform perform_start enqueue_retry retry_stopped discard ]
      .index_with { |operation| "#{operation}.active_job" }.freeze

    def perform_now
      instrument(:perform) { super }
    end

    def instrument(operation, payload = {}) # :nodoc:
      event_name = EVENT_NAMES[operation] || "#{operation}.active_job"

      # Skip event construction entirely when nobody is listening
      unless ActiveSupport::Notifications.notifier.listening?(event_name)
        value = (yield payload if block_given?)
        @_halted_callback_hook_called = nil
        return value
      end

      payload[:job] = self
      payload[:adapter] = queue_adapter

      ActiveSupport::Notifications.instrument(event_name, payload) do |inner_payload|
        value = (yield inner_payload if block_given?)
        inner_payload[:aborted] = true if @_halted_callback_hook_called
        @_halted_callback_hook_called = nil
        value
      end
    end

    private
      # Wraps the same layer the previous around_enqueue callback did (it was
      # registered first, so it always ran outermost), but keeps the enqueue
      # callback chain empty for jobs that define no callbacks of their own
      def raw_enqueue
        scheduled_at ? instrument(:enqueue_at) { super } : instrument(:enqueue) { super }
      end

      def _perform_job
        instrument(:perform_start)
        super
      end

      def halted_callback_hook(*)
        super
        @_halted_callback_hook_called = true
      end
  end
end
