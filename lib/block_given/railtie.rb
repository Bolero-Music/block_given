# frozen_string_literal: true

module BlockGiven
  # Loaded automatically inside a Rails app (Rails 7.0+). Once the app has booted,
  # BlockGiven logs through Rails.logger unless an initializer configured another logger.
  #
  #   # config/initializers/block_given.rb
  #   BlockGiven.configure do |c|
  #     c.connector = BlockGiven::Connectors::Alchemy.new(api_key: Rails.application.credentials.alchemy_api_key)
  #     c.chain = Rails.env.production? ? :base : :base_sepolia
  #   end
  class Railtie < Rails::Railtie
    config.after_initialize do
      BlockGiven.config.logger = Rails.logger if Rails.logger && !BlockGiven.config.logger_configured?
    end
  end
end
