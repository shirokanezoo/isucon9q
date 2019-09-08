require 'json'
require 'uri'
require 'net/http'
require 'expeditor'

module Isucari
  class API
    class Error < StandardError; end

    SHIPMENT_CACHE_TTL = 10

    def redis
      Thread.current[:redis] ||= Redis.new(url: ENV.fetch('REDIS_URL', 'redis://localhost'))
    end

    ISUCARI_API_TOKEN = 'Bearer 75ugk2m37a750fwir5xr-22l6h4wmue1bwrubzwd0'

    def initialize
      @user_agent = 'isucon9-qualify-webapp'

      @expeditor = Expeditor::Service.new(
        executor: Concurrent::ThreadPoolExecutor.new(
          min_threads: 16,
          max_threads: 16,
          max_queue: 100,
        )
      )

    end

    def bulk_shipment_status(shipment_url, ids)
      commands = ids.map do |id|
        Expeditor::Command.new(service: @expeditor) do
          [id, self.shipment_status(shipment_url, id)]
        end
      end
      commands.each(&:start)
      commands.map(&:get).to_h
    end

    def payment_token(payment_url, param)
      uri = URI.parse("#{payment_url}/token")

      req = Net::HTTP::Post.new(uri.path)
      req.body = param.to_json
      req['Content-Type'] = 'application/json'
      req['User-Agent'] = @user_agent

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      res = http.start { http.request(req) }

      if res.code != '200'
        raise Error, "status code #{res.code}; body #{res.body}"
      end

      JSON.parse(res.body)
    end

    def shipment_create(shipment_url, param)
      uri = URI.parse("#{shipment_url}/create")

      req = Net::HTTP::Post.new(uri.path)
      req.body = param.to_json
      req['Content-Type'] = 'application/json'
      req['User-Agent'] = @user_agent
      req['Authorization'] = ISUCARI_API_TOKEN

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      res = http.start { http.request(req) }

      if res.code != '200'
        raise Error, "status code #{res.code}; body #{res.body}"
      end

      json = JSON.parse(res.body)

      reserve_id = json['reserve_id']
      cache_key = "isucari:#{shipment_url}/status/#{reserve_id}"
      redis.set(cache_key, { status: 'initial', reserve_time: json['reserve_time'] }.to_json)

      json
    end

    def shipment_request(shipment_url, reserve_id)
      uri = URI.parse("#{shipment_url}/request")

      req = Net::HTTP::Post.new(uri.path)
      req.body = { reserve_id: reserve_id }.to_json
      req['Content-Type'] = 'application/json'
      req['User-Agent'] = @user_agent
      req['Authorization'] = ISUCARI_API_TOKEN

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      res = http.start { http.request(req) }

      if res.code != '200'
        raise Error, "status code #{res.code}; body #{res.body}"
      end

      cache_key = "isucari:#{shipment_url}/status/#{reserve_id}"
      redis.del(cache_key)

      res.body
    end

    def shipment_status(shipment_url, reserve_id)
      key = "#{shipment_url}/status"
      cache_key = "isucari:#{key}/#{reserve_id}"
      cache = redis.get(cache_key)

      return JSON.parse(cache) if cache

      uri = URI.parse(key)

      req = Net::HTTP::Post.new(uri.path)
      req.body = { reserve_id: reserve_id }.to_json
      req['Content-Type'] = 'application/json'
      req['User-Agent'] = @user_agent
      req['Authorization'] = ISUCARI_API_TOKEN

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      res = http.start { http.request(req) }

      if res.code != '200'
        raise Error, "status code #{res.code}; body #{res.body}"
      end

      json = JSON.parse(res.body)

      if ['initial', 'done'].include?(json['status'])
        redis.set(cache_key, res.body)
      else
        redis.psetex(cache_key, SHIPMENT_CACHE_TTL, res.body)
      end

      json
    end
  end
end
