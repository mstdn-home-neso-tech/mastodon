# frozen_string_literal: true

Chewy.strategy(:mastodon) do
<<<<<<< HEAD
  Dir[Rails.root.join('db', 'seeds', '*.rb')].sort.each do |seed|
=======
  Dir[Rails.root.join('db', 'seeds', '*.rb')].each do |seed|
>>>>>>> v4.2.1
    load seed
  end
end
