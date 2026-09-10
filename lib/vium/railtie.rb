# frozen_string_literal: true

module Vium
  # Loaded automatically inside a Rails app (Rails 7.0+). Once the app has booted,
  # Vium logs through Rails.logger unless an initializer configured another logger.
  #
  #   # config/initializers/vium.rb
  #   Vium.configure do |c|
  #     c.connector = Vium::Connectors::Alchemy.new(api_key: Rails.application.credentials.alchemy_api_key)
  #     c.chain = Rails.env.production? ? :base : :base_sepolia
  #   end
  class Railtie < Rails::Railtie
    config.after_initialize do
      Vium.config.logger = Rails.logger if Rails.logger && !Vium.config.logger_configured?
    end
  end
end
