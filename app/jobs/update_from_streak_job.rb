class UpdateFromStreakJob < ApplicationJob
  queue_as :default

  # Just a quick note, we're going to temporarily disable basic complexity
  # checks from Rubocop for now because this method is going to need a real
  # refactor at some point to implement Streak's V2 API.
  def perform(*) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    # Since we're going to be doing a ton of reflection, we need to make sure
    # that the entire application is loaded into memory.
    Rails.application.eager_load!

    streakable_models = ActiveRecord::Base.descendants.select do |model|
      model.included_modules.include? Streakable
    end

    relationships_to_create = {}

    streakable_models.each do |model|
      model_boxes = StreakClient::Box.all_in_pipeline(model.pipeline_key)

      relationships_to_create[model] = {}

      model_boxes.each do |box|
        instance = model.find_or_initialize_by(model.key_attribute => box[:key])
        attrs_to_update = {}

        attrs_to_update[model.name_attribute] = box[:name]
        attrs_to_update[model.notes_attribute] = box[:notes]

        model.field_mappings.each do |attribute, _|
          key = instance
                .streak_field_and_value_for_attribute(attribute)[:field_key]
          attrs_to_update[attribute] = box[:fields][key.to_sym]
        end

        instance.update_attributes!(attrs_to_update)

        # Delete relationships that aren't present on Streak
        old_linked_box_keys = instance.linked_streak_box_keys
        new_linked_box_keys = box[:linked_box_keys]

        to_del = old_linked_box_keys - new_linked_box_keys
        to_create = new_linked_box_keys - old_linked_box_keys

        model.streakable_associations.each do |association|
          next unless instance.send(:respond_to?, association.plural_name)

          records = instance.send(association.plural_name)
          records_to_remove = records.where(model.key_attribute => to_del)

          records.destroy(records_to_remove)
        end

        relationships_to_create[model][box[:key]] = to_create
      end
    end

    # Create relationships
    relationships_to_create.each do |model, relationships|
      logger.debug "Updating relationships for #{model}"

      relationships.each do |box_key, linked_box_keys|
        instance = model.find_by(model.key_attribute => box_key)

        linked_box_keys.each do |linked_box_key|
          model.streakable_associations.each do |association|
            associated_model = association.klass

            instance_to_associate =
              associated_model.find_by(
                associated_model.key_attribute => linked_box_key
              )

            next if instance_to_associate.nil?

            current_associated = instance.send(association.name)

            if current_associated.is_a? Enumerable
              unless current_associated.include? instance_to_associate
                instance.send(association.name) << instance_to_associate
              end
            else
              logger.debug "Ignoring #{association.name} association because "\
                           "it's not Enumerable. Non-Enumerable association "\
                           "syncing isn't currently implemented."
            end
          end
        end
      end
    end
  end
end
