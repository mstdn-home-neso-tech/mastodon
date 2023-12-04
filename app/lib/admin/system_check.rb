# frozen_string_literal: true

class Admin::SystemCheck
  ACTIVE_CHECKS = [
<<<<<<< HEAD
=======
    Admin::SystemCheck::SoftwareVersionCheck,
>>>>>>> v4.2.1
    Admin::SystemCheck::MediaPrivacyCheck,
    Admin::SystemCheck::DatabaseSchemaCheck,
    Admin::SystemCheck::SidekiqProcessCheck,
    Admin::SystemCheck::RulesCheck,
    Admin::SystemCheck::ElasticsearchCheck,
  ].freeze

  def self.perform(current_user)
    ACTIVE_CHECKS.each_with_object([]) do |klass, arr|
      check = klass.new(current_user)

      if check.skip? || check.pass?
        arr
      else
        arr << check.message
      end
    end
  end
end
