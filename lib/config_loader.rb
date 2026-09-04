# frozen_string_literal: true

require 'yaml'

module RoutingEngine
  module ConfigLoader
    def self.load(path)
      YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
    end
  end
end
