require 'memcached'
require 'sinatra/base'
require 'securerandom'
require 'encryptor'
require 'uri'
require 'yopass/sms_provider'
require 'sinatra/json'
require 'json'

def too_many_tries?(m, key)
  key += key + '_ratelimit'
  begin
    result = m.get key
  rescue Memcached::NotFound
    m.set key, 1, 3600 * 24
    return false
  end
  m.set key, result + 1

  # This dude has tried to many times...
  true if result >= 2
end

class Yopass < Sinatra::Base
  helpers Sinatra::JSON

  configure :development do
    require 'sinatra/reloader'
    register Sinatra::Reloader
  end

  configure do
    set :public_folder, File.dirname(__FILE__) + '/public'
    set :max_length, 10000
    if ENV['YP_SECRET_MAX_LENGTH']
      set :max_length, ENV['YP_SECRET_MAX_LENGTH'].to_i
    end
  end

  get '/v1/secret/:key/:password' do
    m = Memcached.new(ENV['YP_MEMCACHED'] || 'localhost:11211')
    begin
      result = m.get params[:key]
    rescue Memcached::NotFound
      status 404
      return json message: 'Not found'
    end

    begin
      result = Encryptor.decrypt(value: result, key: params[:password])
    rescue OpenSSL::Cipher::CipherError
      m.delete(params[:key]) if too_many_tries?(m, params[:key])
      status 401
      return json message: 'Invalid decryption key'
    end
    m.delete params[:key]
    return json secret: result
  end

  post '/v1/secret' do
    begin
      r = JSON.parse(request.body.read)
    rescue JSON::ParserError
      status 400
      return json message: 'Bad request, seek API docs at https://github.com/jhaals/yopass'
    end

    lifetime = r['lifetime']
    # calculate lifetime in secounds
    lifetime_options = { '1w' => 3600 * 24 * 7,
                         '1d' => 3600 * 24,
                         '1h' => 3600 }

    # Verify that user has posted a valid lifetime
    status 400
    # default lifetime
    lifetime = '1d' if lifetime.nil?
    secret = r['secret']
    return json message: 'Invalid lifetime' unless lifetime_options.include? lifetime
    return json message: 'No secret submitted' if secret.nil?
    return json message: 'No secret submitted' if secret.empty?

    if secret.length >= settings.max_length
      return json message: 'error: This site is meant to store secrets not novels'
    end

    # goes in URL
    key = SecureRandom.hex
    # decryption_key goes in URL or via SMS if provider is configured
    decryption_key = SecureRandom.hex[0..8]
    # encrypt secret with generated decryption_key
    data = Encryptor.encrypt(secret, key: decryption_key)

    m = Memcached.new(ENV['YP_MEMCACHED'] || 'localhost:11211')
    # store secret in memcached
    begin
      m.set key, data, lifetime_options[lifetime]
    rescue Memcached::ServerIsMarkedDead
      status 500
      return json message: 'Error: Unable to contact memcached'
    end
    mobile_number = r['mobile_number']
    if ENV['YP_SEND_SMS'] && !mobile_number.nil?
      unless mobile_number.empty?
        # strip everything except digits
        mobile_number = mobile_number.gsub(/[^0-9]/, '')
        # load SMS provider
        sms_settings = JSON.parse(ENV['YP_SMS_SETTINGS'])
        sms = SmsProvider.create(
          sms_settings['provider'],
          sms_settings['settings'])
        sms.send(mobile_number, decryption_key)
      end
    end
    status 200
    json key: key,
      decryption_key: decryption_key,
      full_url: "/v1/secret/#{key}/#{decryption_key}",
      short_url: "/v1/secret/#{key}",
      message: 'secret stored'
  end

  get '/' do
    # Ugly way of serving index...
    File.read(File.join(settings.public_folder, 'index.html'))
  end
  run! if app_file == $PROGRAM_NAME
end
