require 'base64'
require 'fastlane'
require 'spaceship'

key_id = ENV['APP_STORE_CONNECT_API_KEY_ID']
issuer_id = ENV['APP_STORE_CONNECT_API_ISSUER_ID']
key_content = ENV['APP_STORE_CONNECT_API_KEY_CONTENT']

if key_id.nil? || issuer_id.nil? || key_content.nil?
  puts "App Store Connect credentials missing, skipping capabilities setup"
  exit 0
end

# Decode key content if base64 encoded
decoded_key = key_content
begin
  if Base64.strict_encode64(Base64.decode64(key_content)) == key_content.gsub("\n", '')
    decoded_key = Base64.decode64(key_content)
  end
rescue
  decoded_key = key_content
end

token = Spaceship::ConnectAPI::Token.create(
  key_id: key_id,
  issuer_id: issuer_id,
  key: decoded_key
)
Spaceship::ConnectAPI.token = token

app_identifier = "com.lovelymusic.app"
bundle_id = Spaceship::ConnectAPI::BundleId.find(app_identifier)

if bundle_id.nil?
  puts "Warning: Bundle ID #{app_identifier} not found in App Store Connect"
  exit 0
end

puts "Found Bundle ID for #{app_identifier}: #{bundle_id.id}"

capabilities = []
begin
  capabilities = bundle_id.get_capabilities.map(&:capability_type)
  puts "Current capabilities: #{capabilities.join(', ')}"
rescue => e
  puts "Could not fetch existing capabilities: #{e.message}"
end

required_capabilities = ["PUSH_NOTIFICATIONS", "ICLOUD"]

required_capabilities.each do |cap|
  if capabilities.include?(cap)
    puts "Capability #{cap} is already enabled."
  else
    puts "Enabling #{cap} capability for #{app_identifier}..."
    begin
      bundle_id.create_capability(cap)
      puts "Successfully enabled #{cap}!"
    rescue => e
      puts "Notice while enabling #{cap}: #{e.message}"
    end
  end
end
