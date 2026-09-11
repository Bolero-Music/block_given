# frozen_string_literal: true

module UncleBlockGiven
  # Loaded automatically inside a Rails app (Rails 7.0+). Once the app has booted,
  # UncleBlockGiven logs through Rails.logger unless an initializer configured another logger.
  #
  #   # config/initializers/uncle_block_given.rb
  #   UncleBlockGiven.configure do |c|
  #     c.connector = UncleBlockGiven::Connectors::Alchemy.new(api_key: Rails.application.credentials.alchemy_api_key)
  #     c.chain = Rails.env.production? ? :base : :base_sepolia
  #   end
  class Railtie < Rails::Railtie
    config.after_initialize do
      UncleBlockGiven.config.logger = Rails.logger if Rails.logger && !UncleBlockGiven.config.logger_configured?
    end
  end
end
