# encoding: utf-8
module CartoDB
  module Visualization
    class TableBlender
      def initialize(user, tables=[])
        @user   = user
        @tables = tables
      end

      def blend
        maps            = tables.map(&:map)
        copier          = CartoDB::Map::Copier.new
        destination_map = copier.new_map_from(maps.first).save

        copier.copy_base_layer(maps.first, destination_map)
        maps.each { |map| copier.copy_data_layers(map, destination_map) }
        destination_map
      end

      def blended_privacy
        return Member::PRIVACY_PRIVATE if tables.map(&:privacy_text).include?(Member::PRIVACY_PRIVATE.upcase)
        return Member::PRIVACY_LINK if tables.map(&:privacy_text).include?(Member::PRIVACY_LINK.upcase)
        Member::PRIVACY_PUBLIC
      end

      private

      attr_reader :tables, :user
    end
  end
end

