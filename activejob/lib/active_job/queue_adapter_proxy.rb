# frozen_string_literal: true

require "ractor/dispatch"

module ActiveJob
  # Ractor-shareable wrapper installed in place of the real
  # +ActiveJob::Base._queue_adapter+ at +ractorize!+ time.
  #
  # The real queue adapter (e.g. +ActiveJob::QueueAdapters::AsyncAdapter+)
  # holds non-shareable runtime state — +Concurrent::ThreadPoolExecutor+,
  # +Concurrent::ImmediateExecutor+, +Mutex+ / +ConditionVariable+ inside
  # +Concurrent::ScheduledTask+, etc. Storing it in the singleton-class
  # ivar +@__class_attr__queue_adapter+ on +ActiveJob::Base+ means every
  # read of +ActiveJob::Base._queue_adapter+ from a non-main Ractor
  # raises +Ractor::IsolationError+ ("can not get unshareable values
  # from instance variables of classes/modules from non-main Ractors").
  #
  # That read is on the request hot path:
  #
  #   * +ActiveJob::Instrumentation#perform_now+ -> +instrument(:perform)+
  #     writes +payload[:adapter] = queue_adapter+ on every +perform_now+.
  #   * +ActiveJob::Continuable#monitor+ calls +queue_adapter.stopping?+
  #     when continuable jobs check for shutdown.
  #   * Subscribers under +ActiveJob::StructuredEventSubscriber+ later
  #     consume +payload[:adapter]+ via +ActiveJob.adapter_name(adapter)+.
  #
  # Per the project's design rules (plans/reimplementation/learnings.md):
  # "Use +Ractor::Dispatch+ ONLY for truly Ractor-unsafe external code"
  # and prefer fixing the owner. The queue adapter +is+ inherently unsafe
  # external code (live thread pools, scheduled tasks, queue mutexes) —
  # the same category as the AR connection pool. The proxy mirrors the
  # +ActiveRecord::ConnectionAdapters::RactorConnectionProxy+ shape:
  #
  #   * a deep-frozen, Ractor-shareable wrapper exposing only the
  #     methods reachable from non-main Ractors,
  #   * each method either returns a frozen-snapshot answer captured at
  #     boot, or dispatches to the main Ractor where the real adapter
  #     lives in an unshareable main-only registry, and
  #   * +method_missing+ raises loudly with a pointer back to this file
  #     instead of silently forwarding (the "broad proxy layer can drift
  #     semantically" anti-pattern).
  #
  # The real adapter is stashed at +ActiveJob.real_queue_adapter+ — a
  # plain main-only module ivar accessed via +Ractor::Dispatch.main.run+
  # from non-main, and read directly when already on main. We never make
  # the real adapter shareable (it cannot be), and we never store it in
  # any singleton-class ivar that a class_attribute reader can hit.
  class QueueAdapterProxy
    # +queue_adapter_name+ is the only piece of the adapter that
    # subscribers actually need on the non-main side. +ActiveJob.adapter_name+
    # short-circuits on +respond_to?(:queue_adapter_name)+ before it ever
    # touches +adapter.class+, so the proxy answer never goes through the
    # demodulize/delete_suffix fallback. The captured string is frozen
    # and shareable.
    def initialize(queue_adapter_name)
      raise ArgumentError, "queue_adapter_name must be a String" unless queue_adapter_name.is_a?(String)
      @queue_adapter_name = queue_adapter_name.dup.freeze
      freeze
    end

    attr_reader :queue_adapter_name

    # Forward enqueue to the real adapter. The +Enqueuing#enqueue+ path
    # already routes non-main calls through +_dispatch_enqueue_main+, so
    # +enqueue+ on the proxy is only invoked on the main Ractor in normal
    # operation. Be explicit anyway: dispatch unconditionally so any
    # surprise non-main caller still works correctly instead of raising
    # an opaque IsolationError deep inside the real adapter.
    def enqueue(job)
      if Ractor.main?
        ActiveJob.real_queue_adapter.enqueue(job)
      else
        Ractor::Dispatch.main.run do
          ActiveJob.real_queue_adapter.enqueue(job)
        end
      end
    end

    def enqueue_at(job, timestamp)
      if Ractor.main?
        ActiveJob.real_queue_adapter.enqueue_at(job, timestamp)
      else
        Ractor::Dispatch.main.run do
          ActiveJob.real_queue_adapter.enqueue_at(job, timestamp)
        end
      end
    end

    # +Continuable#monitor+ reads +queue_adapter.stopping?+ on the
    # request path. +AbstractAdapter#stopping?+ returns +!!@stopping+ —
    # +AsyncAdapter+ inherits the default and never sets +@stopping+, so
    # the truthful answer for the default async adapter is always
    # +false+. For other adapters, dispatch to the main side so the real
    # state is read.
    def stopping?
      if Ractor.main?
        ActiveJob.real_queue_adapter.stopping?
      else
        Ractor::Dispatch.main.run do
          !!ActiveJob.real_queue_adapter.stopping?
        end
      end
    end

    def respond_to_missing?(name, include_private = false)
      false
    end

    def method_missing(name, *, **, &)
      raise NoMethodError,
        "#{name} is not implemented on #{self.class} (the Ractor-shareable " \
        "queue adapter proxy). The non-main request surface is intentionally " \
        "limited; if you hit this, extend the proxy at #{__FILE__} or route " \
        "the caller through ActiveJob.real_queue_adapter on the main Ractor."
    end
  end

  class << self
    # Main-only registry for the real (non-shareable) queue adapter
    # instance. Read directly on main; cross via +Ractor::Dispatch.main.run+
    # from non-main. Never stored in any class_attribute / singleton-class
    # ivar reachable from a generated class_attribute reader.
    attr_accessor :real_queue_adapter
  end
end
