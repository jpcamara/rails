# frozen_string_literal: true

require_relative "abstract_unit"
require "active_support/testing/event_reporter_assertions"
require "active_support/log_subscriber/test_helper"

class StructuredEventSubscriberTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::EventReporterAssertions

  class TestEventReporterSubscriber
    def emit(payload)
    end
  end

  class TestSubscriber < ActiveSupport::StructuredEventSubscriber
    class DebugOnlyError < StandardError
    end

    def event(event)
      emit_event("test.event", **event.payload)
    end

    def debug_only_event(event)
      raise DebugOnlyError
    end
    debug_only :debug_only_event
  end

  setup do
    @subscriber = TestSubscriber.new
    @old_debug_mode = ActiveSupport.event_reporter.debug_mode?
    ActiveSupport.event_reporter.debug_mode = false
  end

  teardown do
    ActiveSupport.event_reporter.debug_mode = @old_debug_mode
    TestSubscriber.detach_from :test
    ActiveSupport::StructuredEventSubscriber.detach_from :test
  end

  class LeveledSubscriber < ActiveSupport::StructuredEventSubscriber
    def leveled_event(event)
      emit_event("test.leveled_event", **event.payload)
    end
    emits_at_level :leveled_event, :info
  end

  class InfoLogSubscriber < ActiveSupport::EventReporter::LogSubscriber
    self.namespace = "test"

    def leveled_event(event)
      info "hello"
    end
    event_log_level :leveled_event, :info
  end

  def test_an_event_declared_at_a_level_no_reporter_subscriber_accepts_is_silenced
    reporter = ActiveSupport.event_reporter
    original_subscribers = reporter.subscribers.dup
    reporter.subscribers.clear

    logger = ActiveSupport::LogSubscriber::TestHelper::MockLogger.new(Logger::ERROR)
    InfoLogSubscriber.logger = logger
    subscriber = LeveledSubscriber.new
    LeveledSubscriber.attach_to :test, subscriber

    reporter.subscribe(InfoLogSubscriber.new, &InfoLogSubscriber.subscription_filter)
    assert subscriber.silenced?("leveled_event.test"), "an info event with only an error-level logger listening"

    plain_subscriber = TestEventReporterSubscriber.new
    reporter.subscribe(plain_subscriber)
    assert_not subscriber.silenced?("leveled_event.test"), "a subscriber without a level check keeps the event"

    reporter.unsubscribe(plain_subscriber)
    logger.level = Logger::INFO
    assert_not subscriber.silenced?("leveled_event.test"), "a logger accepting :info keeps the event"
  ensure
    LeveledSubscriber.detach_from :test
    reporter.subscribers.replace(original_subscribers) if original_subscribers
  end

  def test_emit_event_calls_event_reporter_notify
    event = assert_event_reported("test.event", payload: { key: "value" }) do
      @subscriber.emit_event("test.event", { key: "value" })
    end

    assert_equal "test.event", event[:name]
    assert_equal({ key: "value" }, event[:payload])
  end

  def test_emit_debug_event_calls_event_reporter_debug
    with_debug_event_reporting do
      assert_event_reported("test.debug", payload: { debug: "info" }) do
        @subscriber.emit_debug_event("test.debug", { debug: "info" })
      end
    end
  end

  def test_emit_event_handles_errors
    ActiveSupport.event_reporter.stub(:notify, proc { raise StandardError, "event error" }) do
      error_report = assert_error_reported(StandardError) do
        @subscriber.emit_event("test.error")
      end
      assert_equal "test.error", error_report.source
      assert_equal "event error", error_report.error.message
    end
  end

  def test_emit_debug_event_handles_errors
    ActiveSupport.event_reporter.stub(:debug, proc { raise StandardError, "debug error" }) do
      error_report = assert_error_reported(StandardError) do
        @subscriber.emit_debug_event("test.debug_error")
      end
      assert_equal "test.debug_error", error_report.source
      assert_equal "debug error", error_report.error.message
    end
  end

  def test_call_handles_errors
    ActiveSupport::StructuredEventSubscriber.attach_to :test, @subscriber

    event = ActiveSupport::Notifications::Event.new("error_event.test", Time.current, Time.current, "123", {})

    error_report = assert_error_reported(NoMethodError) do
      @subscriber.call(event)
    end
    assert_match(/undefined method (`|')error_event'/, error_report.error.message)
    assert_equal "error_event.test", error_report.source
  end

  def test_debug_only_methods
    TestSubscriber.attach_to :test, @subscriber

    event_reporter_subscriber = TestEventReporterSubscriber.new
    ActiveSupport.event_reporter.subscribe(event_reporter_subscriber)

    assert_no_error_reported do
      ActiveSupport::Notifications.instrument("debug_only_event.test")
    end

    assert_error_reported(TestSubscriber::DebugOnlyError) do
      with_debug_event_reporting do
        ActiveSupport::Notifications.instrument("debug_only_event.test")
      end
    end
  ensure
    ActiveSupport.event_reporter.unsubscribe(event_reporter_subscriber)
  end

  def test_debug_only_does_not_leak_across_subclasses
    base_methods = ActiveSupport::StructuredEventSubscriber.debug_methods.dup

    subscriber_a = Class.new(ActiveSupport::StructuredEventSubscriber) do
      def foo(event); end
      debug_only :foo
    end

    subscriber_b = Class.new(ActiveSupport::StructuredEventSubscriber) do
      def bar(event); end
      debug_only :bar
    end

    assert_equal [:foo], subscriber_a.debug_methods
    assert_equal [:bar], subscriber_b.debug_methods
    assert_equal base_methods, ActiveSupport::StructuredEventSubscriber.debug_methods
  end

  def test_no_event_reporter_subscribers
    ActiveSupport::StructuredEventSubscriber.attach_to :test, @subscriber

    old_subscribers = ActiveSupport.event_reporter.subscribers.dup
    ActiveSupport.event_reporter.subscribers.clear

    assert_not_called @subscriber, :emit_event do
      ActiveSupport::Notifications.instrument("event.test")
    end
  ensure
    ActiveSupport.event_reporter.subscribers.push(*old_subscribers)
  end

  def test_emit_event_does_not_filter_payload
    old_filter_parameters = ActiveSupport.filter_parameters
    ActiveSupport.filter_parameters = [:name, :url, :message, :description]
    ActiveSupport.event_reporter.reload_payload_filter

    event = assert_event_reported("test.event", payload: { name: "Person Load", url: "/test", message: "hello", description: "a thing" }) do
      @subscriber.emit_event("test.event", name: "Person Load", url: "/test", message: "hello", description: "a thing")
    end

    assert_equal "Person Load", event[:payload][:name]
    assert_equal "/test", event[:payload][:url]
    assert_equal "hello", event[:payload][:message]
    assert_equal "a thing", event[:payload][:description]
  ensure
    ActiveSupport.filter_parameters = old_filter_parameters
    ActiveSupport.event_reporter.reload_payload_filter
  end

  def test_emit_debug_event_does_not_filter_payload
    old_filter_parameters = ActiveSupport.filter_parameters
    ActiveSupport.filter_parameters = [:name]
    ActiveSupport.event_reporter.reload_payload_filter

    with_debug_event_reporting do
      event = assert_event_reported("test.debug", payload: { name: "Person Load" }) do
        @subscriber.emit_debug_event("test.debug", name: "Person Load")
      end

      assert_equal "Person Load", event[:payload][:name]
    end
  ensure
    ActiveSupport.filter_parameters = old_filter_parameters
    ActiveSupport.event_reporter.reload_payload_filter
  end
end
