# frozen_string_literal: true

# Only runs when the suite is launched with Rails loaded: RAILS_COMPAT=1 bundle exec rspec
RSpec.describe "BlockGiven::Railtie", if: defined?(Rails::Railtie) do
  it "is registered and defaults the logger to Rails.logger once the app boots" do
    expect(defined?(BlockGiven::Railtie)).to be_truthy

    logger = Logger.new(nil)
    root = Dir.mktmpdir("block_given-rails")
    app_class = Class.new(Rails::Application) do
      config.root = root
      config.eager_load = false
      config.logger = logger
      config.secret_key_base = "block_given-test"
      config.active_support.deprecation = :silence
    end
    stub_const("BlockGivenTestApp::Application", app_class) # Rails derives the app name from the constant
    app_class.initialize!

    # Rails 7.1+ wraps the configured logger in an ActiveSupport::BroadcastLogger
    expect(BlockGiven.config.logger).to equal(Rails.logger)
  ensure
    Rails.app_class = nil if Rails.respond_to?(:app_class=)
    Rails.application = nil if Rails.respond_to?(:application=)
    FileUtils.rm_rf(root) if root
  end
end
