# frozen_string_literal: true

module ARTest
  # Test runner for the `ractor` section: every test method runs in its own
  # short-lived, non-main Ractor while the main Ractor keeps ownership of the
  # physical SQLite connections. Inside the worker Ractor,
  # `ActiveRecord::Base.connection_handler` resolves to the
  # RactorConnectionHandler, so all database access is dispatched back to the
  # main Ractor through RactorConnectionProxy and Ractor::Dispatch.
  module RactorTestRunner
    class << self
      def install
        unless defined?(Ractor::Port)
          raise NotImplementedError, "The ractor test section requires Ractor::Port (Ruby 4.0+)"
        end

        # Load the dispatch executor and the Ractor connection classes on the
        # main Ractor before any worker Ractor needs them, so the executor
        # thread servicing worker queries lives on the main Ractor.
        require "ractor/dispatch"
        [
          ActiveRecord::ConnectionAdapters::RactorConnectionHandler,
          ActiveRecord::ConnectionAdapters::RactorConnectionPool,
          ActiveRecord::ConnectionAdapters::RactorConnectionProxy,
        ].each(&:name)

        # Minitest's run loop reads these constants from the worker Ractor.
        Ractor.make_shareable(Minitest::Test::PASSTHROUGH_EXCEPTIONS)
        Ractor.make_shareable(Minitest::Test::SETUP_METHODS)
        Ractor.make_shareable(Minitest::Test::TEARDOWN_METHODS)

        # What a Ractor-ready application arranges at boot (see the Active
        # Record railtie): worker Ractors read the query transformers from
        # the ActiveRecord module, so they must be shareable.
        Ractor.make_shareable(ActiveRecord.query_transformers)

        ActiveRecord::TestCase.extend(self)
      end

      def run_in_ractor(klass, method_name)
        # Worker Ractors bootstrap their own notifier from the main Ractor's
        # subscription snapshot, which must be shareable. The test
        # environment's main-Ractor subscribers (e.g. SQLCounter) close over
        # unshareable state, so each worker starts from an empty snapshot.
        ActiveSupport::Notifications.notifier_subscriptions = Ractor.make_shareable(
          { string_subscribers: {}, other_subscribers: [] }, copy: true
        )

        port = Ractor::Port.new

        Ractor.new(port, klass, method_name, name: "#{klass}##{method_name}") do |port, test_class, test_method|
          result = test_class.new(test_method).run
          result.failures.map! { |failure| ARTest::RactorTestRunner.portable_failure(failure) }
          port.send(result)
        end.join

        port.receive
      rescue *Minitest::Test::PASSTHROUGH_EXCEPTIONS
        raise
      rescue Exception => error # worker death must become a test error, not kill the run
        aborted_result(klass, method_name, error)
      ensure
        # A worker that died mid-test cannot release the main-side connections
        # pinned to its tokens; reclaim them so they don't leak into the next
        # test.
        ActiveRecord::ConnectionAdapters::RactorConnectionProxy.checkin_all_connections
      end

      # Minitest sanitizes unexpected errors to be marshalable, which usually
      # also makes them copyable between Ractors. Any failure still holding
      # unshareable state (connections, procs, ...) is rebuilt as a plain,
      # copyable failure before crossing back to the main Ractor.
      def portable_failure(failure)
        Ractor.make_shareable(failure, copy: true)
      rescue StandardError
        portable =
          case failure
          when Minitest::UnexpectedError
            error = RuntimeError.new("#{failure.error.class}: #{failure.error.message}")
            error.set_backtrace(Array(failure.error.backtrace).map(&:to_s))
            Minitest::UnexpectedError.new(error)
          else
            failure.class.new(failure.message.to_s)
          end
        portable.set_backtrace(Array(failure.backtrace).map(&:to_s))
        Ractor.make_shareable(portable)
      end

      # Result for a worker Ractor that died before reporting, attributing the
      # Ractor-level error to the test that was running.
      def aborted_result(klass, method_name, error)
        test = klass.new(method_name)
        test.time = 0.0
        test.failures << Minitest::UnexpectedError.new(error.cause || error)
        Minitest::Result.from(test)
      end
    end

    def run(klass, method_name, reporter)
      reporter.prerecord(klass, method_name)
      reporter.record(RactorTestRunner.run_in_ractor(klass, method_name))
    end
  end
end
