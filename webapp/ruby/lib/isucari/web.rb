# rubocop:disable all

require 'redis'
require 'json'
require 'securerandom'
require 'sinatra/base'
require 'mysql2'
require 'mysql2-cs-bind'
require 'bcrypt'
require 'isucari/api'
require 'expeditor'
require 'newrelic_rpm'
require 'new_relic/agent/method_tracer'
require 'new_relic/agent/tracer'

class Mysql2ClientWithNewRelic < Mysql2::Client
  def initialize(*args)
    super
  end

  def query(sql, *args)
    if ENV['LOCAL']
      puts sql
      puts caller(0)[1]
    end
    callback = -> (result, metrics, elapsed) do
      NewRelic::Agent::Datastores.notice_sql(sql, metrics, elapsed)
    end
    op = sql[/^(select|insert|update|delete|begin|commit|rollback)/i] || 'other'
    table = sql[/\bcategories|configs|items|shippings|transaction_evidences|users|user_stats\b/] || 'other'
    NewRelic::Agent::Datastores.wrap('MySQL', op, table, callback) do
      super
    end
  end
end

module Isucari
  class Web < Sinatra::Base
    DEFAULT_PAYMENT_SERVICE_URL = 'https://payment.isucon9q.catatsuy.org'
    DEFAULT_SHIPMENT_SERVICE_URL = 'https://shipment.isucon9q.catatsuy.org'

    ITEM_MIN_PRICE = 100
    ITEM_MAX_PRICE = 1000000
    ITEM_PRICE_ERR_MSG = '商品価格は100ｲｽｺｲﾝ以上、1,000,000ｲｽｺｲﾝ以下にしてください'

    ITEM_STATUS_ON_SALE = 'on_sale'
    ITEM_STATUS_TRADING = 'trading'
    ITEM_STATUS_SOLD_OUT = 'sold_out'
    ITEM_STATUS_STOP = 'stop'
    ITEM_STATUS_CANCEL = 'cancel'

    PAYMENT_SERVICE_ISUCARI_APIKEY = 'a15400e46c83635eb181-946abb51ff26a868317c'
    PAYMENT_SERVICE_ISUCARI_SHOPID = '11'

    TRANSACTION_EVIDENCE_STATUS_WAIT_SHIPPING = 'wait_shipping'
    TRANSACTION_EVIDENCE_STATUS_WAIT_DONE = 'wait_done'
    TRANSACTION_EVIDENCE_STATUS_DONE = 'done'

    SHIPPINGS_STATUS_INITIAL = 'initial'
    SHIPPINGS_STATUS_WAIT_PICKUP = 'wait_pickup'
    SHIPPINGS_STATUS_SHIPPING = 'shipping'
    SHIPPINGS_STATUS_DONE = 'done'

    BUMP_CHARGE_SECONDS = 3

    ITEMS_PER_PAGE = 48
    TRANSACTIONS_PER_PAGE = 10

    BCRYPT_COST = 4

    HOSTNUM = ENV['HOSTNUM']

    EXPEDITOR = Expeditor::Service.new(
      executor: Concurrent::ThreadPoolExecutor.new(
        min_threads: 16,
        max_threads: 16,
        max_queue: 500,
      )
    )

    CATEGORIES = {
      1  => { 'id' =>  1, 'parent_id' =>  0, 'parent_category_name' => nil, 'category_name' => 'ソファー' },
      2  => { 'id' =>  2, 'parent_id' =>  1, 'parent_category_name' => 'ソファー', 'category_name' => '一人掛けソファー' },
      3  => { 'id' =>  3, 'parent_id' =>  1, 'parent_category_name' => 'ソファー', 'category_name' => '二人掛けソファー' },
      4  => { 'id' =>  4, 'parent_id' =>  1, 'parent_category_name' => 'ソファー', 'category_name' => 'コーナーソファー' },
      5  => { 'id' =>  5, 'parent_id' =>  1, 'parent_category_name' => 'ソファー', 'category_name' => '二段ソファー' },
      6  => { 'id' =>  6, 'parent_id' =>  1, 'parent_category_name' => 'ソファー', 'category_name' => 'ソファーベッド' },
      10 => { 'id' => 10, 'parent_id' =>  0, 'parent_category_name' => nil, 'category_name' => '家庭用チェア' },
      11 => { 'id' => 11, 'parent_id' => 10, 'parent_category_name' => '家庭用チェア', 'category_name' => 'スツール' },
      12 => { 'id' => 12, 'parent_id' => 10, 'parent_category_name' => '家庭用チェア', 'category_name' => 'クッションスツール' },
      13 => { 'id' => 13, 'parent_id' => 10, 'parent_category_name' => '家庭用チェア', 'category_name' => 'ダイニングチェア' },
      14 => { 'id' => 14, 'parent_id' => 10, 'parent_category_name' => '家庭用チェア', 'category_name' => 'リビングチェア' },
      15 => { 'id' => 15, 'parent_id' => 10, 'parent_category_name' => '家庭用チェア', 'category_name' => 'カウンターチェア' },
      20 => { 'id' => 20, 'parent_id' =>  0, 'parent_category_name' => nil, 'category_name' => 'キッズチェア' },
      21 => { 'id' => 21, 'parent_id' => 20, 'parent_category_name' => 'キッズチェア', 'category_name' => '学習チェア' },
      22 => { 'id' => 22, 'parent_id' => 20, 'parent_category_name' => 'キッズチェア', 'category_name' => 'ベビーソファ' },
      23 => { 'id' => 23, 'parent_id' => 20, 'parent_category_name' => 'キッズチェア', 'category_name' => 'キッズハイチェア' },
      24 => { 'id' => 24, 'parent_id' => 20, 'parent_category_name' => 'キッズチェア', 'category_name' => 'テーブルチェア' },
      30 => { 'id' => 30, 'parent_id' =>  0, 'parent_category_name' => nil, 'category_name' => 'オフィスチェア' },
      31 => { 'id' => 31, 'parent_id' => 30, 'parent_category_name' => 'オフィスチェア', 'category_name' => 'デスクチェア' },
      32 => { 'id' => 32, 'parent_id' => 30, 'parent_category_name' => 'オフィスチェア', 'category_name' => 'ビジネスチェア' },
      33 => { 'id' => 33, 'parent_id' => 30, 'parent_category_name' => 'オフィスチェア', 'category_name' => '回転チェア' },
      34 => { 'id' => 34, 'parent_id' => 30, 'parent_category_name' => 'オフィスチェア', 'category_name' => 'リクライニングチェア' },
      35 => { 'id' => 35, 'parent_id' => 30, 'parent_category_name' => 'オフィスチェア', 'category_name' => '投擲用椅子' },
      40 => { 'id' => 40, 'parent_id' =>  0, 'parent_category_name' => nil, 'category_name' => '折りたたみ椅子' },
      41 => { 'id' => 41, 'parent_id' => 40, 'parent_category_name' => '折りたたみ椅子', 'category_name' => 'パイプ椅子' },
      42 => { 'id' => 42, 'parent_id' => 40, 'parent_category_name' => '折りたたみ椅子', 'category_name' => '木製折りたたみ椅子' },
      43 => { 'id' => 43, 'parent_id' => 40, 'parent_category_name' => '折りたたみ椅子', 'category_name' => 'キッチンチェア' },
      44 => { 'id' => 44, 'parent_id' => 40, 'parent_category_name' => '折りたたみ椅子', 'category_name' => 'アウトドアチェア' },
      45 => { 'id' => 45, 'parent_id' => 40, 'parent_category_name' => '折りたたみ椅子', 'category_name' => '作業椅子' },
      50 => { 'id' => 50, 'parent_id' =>  0, 'parent_category_name' => nil, 'category_name' => 'ベンチ' },
      51 => { 'id' => 51, 'parent_id' => 50, 'parent_category_name' => 'ベンチ', 'category_name' => '一人掛けベンチ' },
      52 => { 'id' => 52, 'parent_id' => 50, 'parent_category_name' => 'ベンチ', 'category_name' => '二人掛けベンチ' },
      53 => { 'id' => 53, 'parent_id' => 50, 'parent_category_name' => 'ベンチ', 'category_name' => 'アウトドア用ベンチ' },
      54 => { 'id' => 54, 'parent_id' => 50, 'parent_category_name' => 'ベンチ', 'category_name' => '収納付きベンチ' },
      55 => { 'id' => 55, 'parent_id' => 50, 'parent_category_name' => 'ベンチ', 'category_name' => '背もたれ付きベンチ' },
      56 => { 'id' => 56, 'parent_id' => 50, 'parent_category_name' => 'ベンチ', 'category_name' => 'ベンチマーク' },
      60 => { 'id' => 60, 'parent_id' =>  0, 'parent_category_name' => nil, 'category_name' => '座椅子' },
      61 => { 'id' => 61, 'parent_id' => 60, 'parent_category_name' => '座椅子', 'category_name' => '和風座椅子' },
      62 => { 'id' => 62, 'parent_id' => 60, 'parent_category_name' => '座椅子', 'category_name' => '高座椅子' },
      63 => { 'id' => 63, 'parent_id' => 60, 'parent_category_name' => '座椅子', 'category_name' => 'ゲーミング座椅子' },
      64 => { 'id' => 64, 'parent_id' => 60, 'parent_category_name' => '座椅子', 'category_name' => 'ロッキングチェア' },
      65 => { 'id' => 65, 'parent_id' => 60, 'parent_category_name' => '座椅子', 'category_name' => '座布団' },
      66 => { 'id' => 66, 'parent_id' => 60, 'parent_category_name' => '座椅子', 'category_name' => '空気椅子' },
    }.freeze
    CATEGORIES_PER_PARENT = CATEGORIES.each_value.group_by { |_| _['parent_id'] }
    CATEGORIE_IDS_PER_PARENT = CATEGORIES_PER_PARENT.transform_values { |_| _.map { |c|  c['id'] } }



    configure :development do
      require 'sinatra/reloader'
      register Sinatra::Reloader
    end

    set :add_charset, ['application/json']
    set :public_folder, File.join(__dir__, '..', '..', 'public')
    set :root, File.join(__dir__, '..', '..')
    set :session_secret, 'tagomoris'
    set :sessions, 'key' => 'isucari_session', 'expire_after' => 3600

    helpers do
      def db
        return Thread.current[:db] if Thread.current[:db]
        params = {
          'host' => ENV['MYSQL_HOST'] || '127.0.0.1',
          'port' => ENV['MYSQL_PORT'] || '3306',
          'database' => ENV['MYSQL_DBNAME'] || 'isucari',
          'username' => ENV['MYSQL_USER'] || 'isucari',
          'password' => ENV['MYSQL_PASS'] || 'isucari',
          'charset' => 'utf8mb4',
          'database_timezone' => :local,
          'cast_booleans' => true,
          'reconnect' => true,
        }
        Thread.current[:db] = ENV['NEW_RELIC_AGENT_ENABLED'] ? Mysql2ClientWithNewRelic.new(params) : Mysql2::Client.new(params)
      end

      def redis
        Thread.current[:redis] ||= Redis.new(url: ENV.fetch('REDIS_URL', 'redis://localhost'))
      end

      def api_client
        Thread.current[:api_client] ||= ::Isucari::API.new
      end

      def get_user
        user_id = session['user_id']

        return unless user_id

        db.xquery('SELECT `user_stats`.* FROM `user_stats` WHERE `id` = ?', user_id).first
      end

      def get_current_user_id
        session['user_id'].to_i
      end

      def category_id_for_user
        ids = CATEGORIES.keys
        [
          ids[get_current_user_id % ids.length],
          ids[(get_current_user_id + 1) % ids.length],
          ids[(get_current_user_id + 2) % ids.length],
        ]
      end

      def get_user_simple_by_ids(user_ids)
        users = {}
        db.xquery('SELECT id, account_name, num_sell_items FROM `user_stats` WHERE `id` IN (?)', user_ids).each do |user|
          users[user['id']] = {
            'id' => user['id'],
            'account_name' => user['account_name'],
            'num_sell_items' => user['num_sell_items']
          }
        end
        users
      end

      def get_user_simple_by_id(user_id)
        user = db.xquery('SELECT `user_stats`.`id`, `user_stats`.`account_name`, `user_stats`.`num_sell_items` FROM `user_stats` WHERE `user_stats`.`id` = ?', user_id).first

        return if user.nil?

        {
          'id' => user['id'],
          'account_name' => user['account_name'],
          'num_sell_items' => user['num_sell_items']
        }
      end

      def get_category_by_id(category_id)
        CATEGORIES[category_id.to_i]
      end

      def get_config_by_name(name)
        return redis.get("isucari:config:#{name}")

        #config = db.xquery('SELECT * FROM `configs` WHERE `name` = ?', name).first

        #return if config.nil?

        #config['val']
      end

      def get_payment_service_url
        @payment_service_url ||= get_config_by_name('payment_service_url') || DEFAULT_PAYMENT_SERVICE_URL
      end

      def get_shipment_service_url
        @shipment_service_url ||= get_config_by_name('shipment_service_url') || DEFAULT_SHIPMENT_SERVICE_URL
      end

      if ENV['LOCAL']
        def get_image_url(image_name)
          "https://isucon9.catatsuy.org/upload/#{image_name}"
        end
      else
        def get_image_url(image_name)
          "/upload/#{image_name}"
        end
      end


      def body_params
        @body_params ||= JSON.parse(request.body.tap(&:rewind).read)
      end

      def halt_with_error(status = 500, error = 'unknown')
        halt status, { 'error' => error }.to_json
      end

      def cache_with(key, options = {}, &block)
        return block.call if ENV['NO_CACHE']

        key = "isucari:#{key}"
        cache = redis.get(key)
        return cache if cache && (options[:if].nil? || options[:if])

        cache = block.call
        redis.set(key, cache) if options[:if].nil? || options[:if]

        cache
      end

      def purge_cache(*keys)
        return if ENV['NO_CACHE']

        keys.each do |key|
          redis.del("isucari:#{key}")
        end
      end

      def purge_item(item)
        return if ENV['NO_CACHE']

        purge_cache("new_items")
        purge_cache("items/#{item['id']}")
        purge_category({ 'id' => item['category_id'] })
        purge_user({ 'id' => item['seller_id'] })
        purge_user({ 'id' => item['buyer_id'] }) if item['buyer_id'] && item['buyer_id'] > 0
      end

      def purge_category(category)
        return if ENV['NO_CACHE']

        category = get_category_by_id(category['id'])
        purge_cache("categories/#{category['id']}")
        purge_cache("categories/#{category['parent_id']}")
      end

      def purge_user(user)
        return if ENV['NO_CACHE']

        purge_cache("users/#{user['id']}")
      end
    end

    # API

    # postInitialize
    post '/initialize' do
      redis.keys('isucari:*').each_slice(100) do |ks|
        redis.del(*ks)
      end
      unless system "#{settings.root}/../sql/init.sh"
        halt_with_error 500, 'exec init.sh error'
      end

      ['payment_service_url', 'shipment_service_url'].each do |name|
        value = body_params[name]

        redis.set("isucari:config:#{name}", value)
        db.xquery('INSERT INTO `configs` (name, val) VALUES (?, ?) ON DUPLICATE KEY UPDATE `val` = VALUES(`val`)', name, value)
      end

      content_type :json

      response = {
        # キャンペーン実施時には還元率の設定を返す。詳しくはマニュアルを参照のこと。
        'campaign' => 3,
        # 実装言語を返す
        'language' => 'ruby',
      }

      response.to_json
    end

    # getNewItems
    get '/new_items.json' do
      item_id = params['item_id'].to_i
      created_at = params['created_at'].to_i

      cache_with('new_items', if: item_id == 0 && created_at == 0) do
        items = if item_id > 0 && created_at > 0
          NewRelic::Agent.set_transaction_name('GET /new_items.json (with params)')
          # paging
          db.xquery(
            "SELECT `items`.*, " \
            "`user_stats`.`account_name`, `user_stats`.`num_sell_items`, " \
            "`categories`.`parent_id`, `categories`.`category_name` " \
            "FROM `items` " \
            "INNER JOIN `user_stats` ON `user_stats`.`user_id` = `items`.`seller_id` " \
            "INNER JOIN `categories` ON `items`.`category_id` = `categories`.`id` " \
            "WHERE `items`.`status` IN (?) " \
            "AND `items`.`category_id` IN (?) " \
            "AND `items`.`seller_id` != ? " \
            "AND (`items`.`created_at` < ?  OR (`items`.`created_at` <= ? AND `items`.`id` < ?)) " \
            "ORDER BY `items`.`created_at` DESC, `items`.`id` DESC LIMIT #{ITEMS_PER_PAGE + 1}",
            [ITEM_STATUS_ON_SALE],
            category_id_for_user, # FIX: ユーザーごとに
            get_current_user_id,
            Time.at(created_at),
            Time.at(created_at),
            item_id
          )
        else
          NewRelic::Agent.set_transaction_name('GET /new_items.json (w/o params)')
          # 1st page
          db.xquery(
            "SELECT `items`.*, " \
            "`user_stats`.`account_name`, `user_stats`.`num_sell_items`, " \
            "`categories`.`parent_id`, `categories`.`category_name` " \
            "FROM `items` " \
            "INNER JOIN `user_stats` ON `user_stats`.`user_id` = `items`.`seller_id` " \
            "INNER JOIN `categories` ON `items`.`category_id` = `categories`.`id` " \
            "WHERE `status` IN (?) " \
            "AND `items`.`category_id` IN (?) " \
            "AND `items`.`seller_id` != ? " \
            "ORDER BY `items`.`created_at` DESC, `items`.`id` DESC LIMIT #{ITEMS_PER_PAGE + 1}",
            [ITEM_STATUS_ON_SALE],
            category_id_for_user, # FIX: ユーザーごとに
            get_current_user_id
          )
        end

        item_simples = items.map do |item|
          seller = {
            'id' => item['seller_id'],
            'account_name' => item['account_name'],
            'num_sell_items' => item['num_sell_items']
          }
          halt_with_error 404, 'seller not found' if seller.nil?

          parent_category_name = item['parent_id'] ? get_category_by_id(item['parent_id'])['category_name'] : nil
          category = {
            'id' => item['category_id'],
            'parent_id' => item['parent_id'],
            'category_name' => item['category_name'],
            'parent_category_name' => parent_category_name
          }
          halt_with_error 404, 'category not found' if category.nil?

          {
            'id' => item['id'],
            'seller_id' => item['seller_id'],
            'seller' => seller,
            'status' => item['status'],
            'name' => item['name'],
            'price' => item['price'],
            'image_url' => get_image_url(item['image_name']),
            'category_id' => item['category_id'],
            'category' => category,
            'created_at' => item['created_at'].to_i
          }
        end

        has_next = false
        if item_simples.length > ITEMS_PER_PAGE
          has_next = true
          item_simples = item_simples[0, ITEMS_PER_PAGE]
        end

        response = {
          'items' => item_simples,
          'has_next' => has_next
        }

        response.to_json
      end
    end

    # getNewCategoryItems
    get '/new_items/:root_category_id.json' do
      root_category_id = params['root_category_id'].to_i
      halt_with_error 400, 'incorrect category id' if root_category_id <= 0

      item_id = params['item_id'].to_i
      created_at = params['created_at'].to_i

      cache_with("categories/#{root_category_id}", if: item_id == 0 && created_at == 0) do
        root_category = get_category_by_id(root_category_id)
        halt_with_error 404, 'category not found' if root_category.nil?

        category_ids = CATEGORIE_IDS_PER_PARENT[root_category_id]

        items = if item_id > 0 && created_at > 0
          NewRelic::Agent.set_transaction_name('GET /new_items/:root_category_id.json (with params)')
          db.xquery(
            "SELECT `items`.*, " \
            "`user_stats`.`account_name`, `user_stats`.`num_sell_items` " \
            "FROM `items` " \
            "INNER JOIN `user_stats` ON `user_stats`.`user_id` = `items`.`seller_id` " \
            "WHERE `items`.`status` IN (?, ?) " \
            "AND `items`.`category_id` IN (?) " +
            "AND (`items`.`created_at` < ?  OR (`items`.`created_at` <= ? AND `items`.`id` < ?)) " \
            "ORDER BY `items`.`created_at` DESC, `items`.`id` DESC LIMIT #{ITEMS_PER_PAGE + 1}",
            ITEM_STATUS_ON_SALE,
            ITEM_STATUS_SOLD_OUT,
            category_ids,
            Time.at(created_at),
            Time.at(created_at),
            item_id
          )
        else
          NewRelic::Agent.set_transaction_name('GET /new_items/:root_category_id.json (w/o params)')
          db.xquery(
            "SELECT `items`.*, " \
            "`user_stats`.`account_name`, `user_stats`.`num_sell_items` " \
            "FROM `items` " \
            "INNER JOIN `user_stats` ON `user_stats`.`user_id` = `items`.`seller_id` " \
            "WHERE `items`.`status` IN (?, ?) " \
            "AND `items`.`category_id` IN (?) " +
            "ORDER BY `items`.`created_at` DESC, `items`.`id` DESC LIMIT #{ITEMS_PER_PAGE + 1}",
            ITEM_STATUS_ON_SALE,
            ITEM_STATUS_SOLD_OUT,
            category_ids
          )
        end

        item_simples = items.map do |item|
          seller = {
            'id' => item['seller_id'],
            'account_name' => item['account_name'],
            'num_sell_items' => item['num_sell_items']
          }
          halt_with_error 404, 'seller not found' if seller.nil?

          category = get_category_by_id(item['category_id'])
          halt_with_error 404, 'category not found' if category.nil?

          {
            'id' => item['id'],
            'seller_id' => item['seller_id'],
            'seller' => seller,
            'status' => item['status'],
            'name' => item['name'],
            'price' => item['price'],
            'image_url' => get_image_url(item['image_name']),
            'category_id' => item['category_id'],
            'category' => category,
            'created_at' => item['created_at'].to_i
          }
        end

        has_next = false
        if item_simples.length > ITEMS_PER_PAGE
          has_next = true
          item_simples = item_simples[0, ITEMS_PER_PAGE]
        end

        response = {
          'root_category_id' => root_category['id'],
          'root_category_name' => root_category['category_name'],
          'items' => item_simples,
          'has_next' => has_next
        }

        response.to_json
      end
    end

    # getTransactions
    get '/users/transactions.json' do
      user = get_user

      item_id = params['item_id'].to_i
      created_at = params['created_at'].to_i

      db.query('BEGIN')
      items = if item_id > 0 && created_at > 0
        # paging
        begin
          NewRelic::Agent.set_transaction_name('GET /users/transactions.json (with params)')
          db.xquery(
            "SELECT `items`.*, " \
            "`user_stats`.`account_name`, `user_stats`.`num_sell_items` " \
            ", `buyer_stats`.`account_name` AS `buyer_name`, " \
            "`buyer_stats`.`num_sell_items` AS `buyer_num_sell_items` " \
            "FROM `items` " \
            "INNER JOIN `user_stats` ON `user_stats`.`user_id` = `items`.`seller_id`" \
            "LEFT OUTER JOIN `user_stats` `buyer_stats` ON `buyer_stats`.`user_id` = `items`.`buyer_id` " \
            "WHERE (`items`.`seller_id` = ? OR `items`.`buyer_id` = ?) " \
            "AND `items`.`status` IN (?) " \
            "AND (`items`.`created_at` < ?  OR (`items`.`created_at` <= ? AND `items`.`id` < ?)) " \
            "ORDER BY `items`.`created_at` DESC, `items`.`id` DESC LIMIT #{TRANSACTIONS_PER_PAGE + 1}",
            user['id'],
            user['id'],
            [ITEM_STATUS_ON_SALE, ITEM_STATUS_TRADING, ITEM_STATUS_SOLD_OUT, ITEM_STATUS_CANCEL, ITEM_STATUS_STOP],
            Time.at(created_at),
            Time.at(created_at),
            item_id
          )
        rescue => e
          puts e.full_message
          db.query('ROLLBACK')
          halt_with_error 500, 'db error'
        end
      else
        NewRelic::Agent.set_transaction_name('GET /users/transactions.json (w/o params)')
        # 1st page
        begin
          db.xquery(
            "SELECT `items`.*, " \
            "`user_stats`.`account_name`, `user_stats`.`num_sell_items` " \
            ", `buyer_stats`.`account_name` AS `buyer_name`, " \
            "`buyer_stats`.`num_sell_items` AS `buyer_num_sell_items` " \
            "FROM `items` " \
            "INNER JOIN `user_stats` ON `user_stats`.`user_id` = `items`.`seller_id`" \
            "LEFT OUTER JOIN `user_stats` `buyer_stats` ON `buyer_stats`.`user_id` = `items`.`buyer_id` " \
            "WHERE (`items`.`seller_id` = ? OR `items`.`buyer_id` = ?) " \
            "AND `items`.`status` IN (?) " \
            "ORDER BY `items`.`created_at` DESC, `items`.`id` DESC LIMIT #{TRANSACTIONS_PER_PAGE + 1}",
            user['id'],
            user['id'],
            [ITEM_STATUS_ON_SALE, ITEM_STATUS_TRADING, ITEM_STATUS_SOLD_OUT, ITEM_STATUS_CANCEL, ITEM_STATUS_STOP]
          )
        rescue => e
          puts e.full_message
          db.query('ROLLBACK')
          halt_with_error 500, 'db error'
        end
      end

      shippings = db.xquery(
        "SELECT " \
        "  `transaction_evidences`.`item_id`" \
        "  , `transaction_evidences`.`id` as `transaction_evidence_id`" \
        "  , `transaction_evidences`.`status` as `transaction_evidence_status`" \
        "  , `shippings`.`reserve_id`" \
        "FROM `transaction_evidences` " \
        "INNER JOIN `shippings` ON `shippings`.`transaction_evidence_id` = `transaction_evidences`.`id` " \
        "WHERE `transaction_evidences`.`item_id` IN (#{items.map{ |_| _['id'] }.join(', ')})"
      ).map do |row|
        [row['item_id'], row]
      end.to_h

      ssrs = begin
        api_client.bulk_shipment_status(get_shipment_service_url, shippings.each_value.map { |_|  _['reserve_id'] })
      rescue => e
        $stderr.puts e.full_message
        db.query('ROLLBACK')
        halt_with_error 500, 'failed to request to shipment service'
      end

      item_details = items.map do |item|
        seller = {
          'id' => item['seller_id'],
          'account_name' => item['account_name'],
          'num_sell_items' => item['num_sell_items']
        }
        if seller.nil?
          db.query('ROLLBACK')
          halt_with_error 404, 'seller not found'
        end

        category = get_category_by_id(item['category_id'])
        if category.nil?
          db.query('ROLLBACK')
          halt_with_error 404, 'category not found'
        end

        item_detail = {
          'id' => item['id'],
          'seller_id' => item['seller_id'],
          'seller' => seller,
          # buyer_id
          # buyer
          'status' => item['status'],
          'name' => item['name'],
          'price' => item['price'],
          'description' => item['description'],
          'image_url' => get_image_url(item['image_name']),
          'category_id' => item['category_id'],
          # transaction_evidence_id
          # transaction_evidence_status
          # shipping_status
          'category' => category,
          'created_at' => item['created_at'].to_i
        }

        if item['buyer_id'] != 0
          item_detail['buyer_id'] = item['buyer_id']
          item_detail['buyer'] = {
            'id' => item['buyer_id'],
            'account_name' => item['buyer_name'],
            'num_sell_items' => item['buyer_num_sell_items']
          }
        end

        shipping = shippings[item['id']]
        if shipping
          ssr = ssrs.fetch shipping['reserve_id']
          item_detail['transaction_evidence_id'] = shipping['transaction_evidence_id']
          item_detail['transaction_evidence_status'] = shipping['transaction_evidence_status']
          item_detail['shipping_status'] = ssr['status']
        end

        item_detail
      end

      db.query('COMMIT')

      has_next = false
      if item_details.length > TRANSACTIONS_PER_PAGE
        has_next = true
        item_details = item_details[0, TRANSACTIONS_PER_PAGE]
      end

      response = {
        'items' => item_details,
        'has_next' => has_next
      }

      response.to_json
    end

    # getUserItems
    get '/users/:user_id.json' do
      user_id = params['user_id'].to_i

      halt_with_error 400, 'incorrect user id' if user_id <= 0

      item_id = params['item_id'].to_i
      created_at = params['created_at'].to_i

      cache_with("users/#{user_id}", if: item_id == 0 && created_at == 0) do
        user_simple = get_user_simple_by_id(user_id)
        halt_with_error 404, 'user not found' if user_simple.nil?

        items = if item_id > 0 && created_at > 0
          # paging
          db.xquery("SELECT * FROM `items` WHERE `seller_id` = ? AND `status` IN (?, ?, ?) AND `created_at` <= ? AND `id` < ? ORDER BY `created_at` DESC, `id` DESC LIMIT #{ITEMS_PER_PAGE + 1}", user_simple['id'], ITEM_STATUS_ON_SALE, ITEM_STATUS_TRADING, ITEM_STATUS_SOLD_OUT, Time.at(created_at), item_id)
        else
          # 1st page
          db.xquery("SELECT * FROM `items` WHERE `seller_id` = ? AND `status` IN (?, ?, ?) ORDER BY `created_at` DESC, `id` DESC LIMIT #{ITEMS_PER_PAGE + 1}", user_simple['id'], ITEM_STATUS_ON_SALE, ITEM_STATUS_TRADING, ITEM_STATUS_SOLD_OUT)
        end

        item_simples = items.map do |item|
          seller = get_user_simple_by_id(item['seller_id'])
          halt_with_error 404, 'seller not found' if seller.nil?

          category = get_category_by_id(item['category_id'])
          halt_with_error 404, 'category not found' if category.nil?

          {
            'id' => item['id'],
            'seller_id' => item['seller_id'],
            'seller' => seller,
            'status' => item['status'],
            'name' => item['name'],
            'price' => item['price'],
            'image_url' => get_image_url(item['image_name']),
            'category_id' => item['category_id'],
            'category' => category,
            'created_at' => item['created_at'].to_i
          }
        end

        has_next = false
        if item_simples.length > ITEMS_PER_PAGE
          has_next = true
          item_simples = item_simples[0, ITEMS_PER_PAGE]
        end

        response = {
          'user' => user_simple,
          'items' => item_simples,
          'has_next' => has_next
        }

        response.to_json
      end
    end

    # getItem
    get '/items/:item_id.json' do
      item_id = params['item_id'].to_i
      halt_with_error 400, 'incorrect item id' if item_id <= 0

      cache_with("items/#{item_id}") do
        user = get_user

        item = db.xquery('SELECT * FROM `items` WHERE `id` = ?', item_id).first
        halt_with_error 404, 'item not found' if item.nil?

        category = get_category_by_id(item['category_id'])
        halt_with_error 404, 'category not found' if category.nil?

        seller = get_user_simple_by_id(item['seller_id'])
        halt_with_error 404, 'seller not found' if seller.nil?

        item_detail = {
          'id' => item['id'],
          'seller_id' => item['seller_id'],
          'seller' => seller,
          # buyer_id
          # buyer
          'status' => item['status'],
          'name' => item['name'],
          'price' => item['price'],
          'description' => item['description'],
          'image_url' => get_image_url(item['image_name']),
          'category_id' => item['category_id'],
          # transaction_evidence_id
          # transaction_evidence_status
          # shipping_status
          'category' => category,
          'created_at' => item['created_at'].to_i
        }

        if (user['id'] == item['seller_id'] || user['id'] == item['buyer_id']) && item['buyer_id'] != 0
          buyer = get_user_simple_by_id(item['buyer_id'])
          halt_with_error 404, 'buyer not found' if buyer.nil?

          item_detail['buyer_id'] = item['buyer_id']
          item_detail['buyer'] = buyer

          transaction_evidence = db.xquery('SELECT * FROM `transaction_evidences` WHERE `item_id` = ?', item['id']).first
          unless transaction_evidence.nil?
            shipping = db.xquery('SELECT * FROM `shippings` WHERE `transaction_evidence_id` = ?', transaction_evidence['id']).first
            halt_with_error 404, 'shipping not found' if shipping.nil?

            item_detail['transaction_evidence_id'] = transaction_evidence['id']
            item_detail['transaction_evidence_status'] = transaction_evidence['status']
            item_detail['shipping_status'] = shipping['status']
          end
        end

        item_detail.to_json
      end
    end

    # postItemEdit
    post '/items/edit' do
      csrf_token = body_params['csrf_token']
      item_id = body_params['item_id'].to_i
      price = body_params['item_price'].to_i

      halt_with_error 422, 'csrf token error' if csrf_token != session['csrf_token']

      if price < ITEM_MIN_PRICE || price > ITEM_MAX_PRICE
        halt_with_error 400, ITEM_PRICE_ERR_MSG
      end

      seller = get_user
      halt_with_error 404, 'user not found' if seller.nil?

      target_item = db.xquery('SELECT * FROM `items` WHERE `id` = ?', item_id).first
      halt_with_error 404, 'item not found' if target_item.nil?

      if target_item['seller_id'] != seller['id']
        halt_with_error 403, '自分の商品以外は編集できません'
      end

      db.query('BEGIN')

      target_item = db.xquery('SELECT * FROM `items` WHERE `id` = ? FOR UPDATE', item_id).first

      if target_item['status'] != ITEM_STATUS_ON_SALE
        db.query('ROLLBACK')
        halt_with_error 403, '販売中の商品以外編集できません'
      end

      begin
        db.xquery('UPDATE `items` SET `price` = ?, `updated_at` = ? WHERE `id` = ?', price, Time.now(), item_id)
      rescue => e
        puts e.full_message
        db.query('ROLLBACK')
        halt_with_error 500, 'db error'
      end

      target_item = db.xquery('SELECT * FROM `items` WHERE `id` = ?', item_id).first

      db.query('COMMIT')
      purge_item(target_item)

      response = {
        'item_id' => target_item['id'],
        'item_price' => target_item['price'],
        'item_created_at' => target_item['created_at'].to_i,
        'item_updated_at' => target_item['updated_at'].to_i
      }

      response.to_json
    end

    # postBuy
    post '/buy' do
      csrf_token = body_params['csrf_token']
      item_id = body_params['item_id'].to_i
      token = body_params['token']

      halt_with_error 422, 'csrf token error' if csrf_token != session['csrf_token']

      buyer = get_user
      halt_with_error 404, 'buyer not found' if buyer.nil?

      db.query('BEGIN')

      begin
        target_item = db.xquery('SELECT * FROM `items` WHERE `id` = ? FOR UPDATE', item_id).first

        if target_item.nil?
          db.query('ROLLBACK')
          halt_with_error 404, 'item not found'
        end
      rescue => e
        puts e.full_message
        db.query('ROLLBACK')
        halt_with_error 500, 'db error'
      end

      if target_item['status'] != ITEM_STATUS_ON_SALE
        db.query('ROLLBACK')
        halt_with_error 403, 'item is not for sale'
      end

      if target_item['seller_id'] == buyer['id']
        db.query('ROLLBACK')
        halt_with_error 403, '自分の商品は買えません'
      end

      begin
        seller = db.xquery('SELECT * FROM `users` WHERE `id` = ?', target_item['seller_id']).first

        if seller.nil?
          db.query('ROLLBACK')
          halt_with_error 404, 'seller not found'
        end
      rescue => e
        puts e.full_message
        db.query('ROLLBACK')
        halt_with_error 500, 'db error'
      end

      category = get_category_by_id(target_item['category_id'])
      if category.nil?
        db.query('ROLLBACK')
        halt_with_error 500, 'category id error'
      end

      begin
        db.xquery('INSERT INTO `transaction_evidences` (`seller_id`, `buyer_id`, `status`, `item_id`, `item_name`, `item_price`, `item_description`,`item_category_id`,`item_root_category_id`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)', target_item['seller_id'], buyer['id'], TRANSACTION_EVIDENCE_STATUS_WAIT_SHIPPING, target_item['id'], target_item['name'], target_item['price'], target_item['description'], category['id'], category['parent_id'])
      rescue => e
        puts e.full_message
        db.query('ROLLBACK')
        halt_with_error 500, 'db error'
      end

      transaction_evidence_id = db.last_id

      begin
        db.xquery('UPDATE `items` SET `buyer_id` = ?, `status` = ?, `updated_at` = ? WHERE `id` = ?', buyer['id'], ITEM_STATUS_TRADING, Time.now, target_item['id'])
      rescue => e
        puts e.full_message
        db.query('ROLLBACK')
        halt_with_error 500, 'db error'
      end

      shipment = Expeditor::Command.new(service: EXPEDITOR) do
        api_client.shipment_create(get_shipment_service_url, to_address: buyer['address'], to_name: buyer['account_name'], from_address: seller['address'], from_name: seller['account_name'])
      end
      shipment.start_with_retry(tries: 3, sleep: 1, on: [StandardError])
      payment = Expeditor::Command.new(service: EXPEDITOR) do
        api_client.payment_token(get_payment_service_url, shop_id: PAYMENT_SERVICE_ISUCARI_SHOPID, token: token, api_key: PAYMENT_SERVICE_ISUCARI_APIKEY, price: target_item['price'])
      end
      payment.start_with_retry(tries: 3, sleep: 1, on: [StandardError])

      begin
        scr = shipment.get
      rescue => e
        puts e.full_message
        db.query('ROLLBACK')
        halt_with_error 500, 'failed to request to shipment service'
      end

      begin
        pstr = payment.get
      rescue
        db.query('ROLLBACK')
        halt_with_error 500, 'payment service is failed'
      end

      if pstr['status'] == 'invalid'
        db.query('ROLLBACK')
        halt_with_error 400, 'カード情報に誤りがあります'
      end

      if pstr['status'] == 'fail'
        db.query('ROLLBACK')
        halt_with_error 400, 'カードの残高が足りません'
      end

      if pstr['status'] != 'ok'
        db.query('ROLLBACK')
        halt_with_error 400, '想定外のエラー'
      end

      begin
        db.xquery('INSERT INTO `shippings` (`transaction_evidence_id`, `status`, `item_name`, `item_id`, `reserve_id`, `reserve_time`, `to_address`, `to_name`, `from_address`, `from_name`, `image_name`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', transaction_evidence_id, SHIPPINGS_STATUS_INITIAL, target_item['name'], target_item['id'], scr['reserve_id'], scr['reserve_time'], buyer['address'], buyer['account_name'], seller['address'], seller['account_name'], nil)
      rescue
        db.query('ROLLBACK')
        halt_with_error 500, 'db error'
      end

      db.query('COMMIT')
      purge_item(target_item)

      { 'transaction_evidence_id' => transaction_evidence_id }.to_json
    end

    # postSell
    post '/sell' do
      csrf_token = params['csrf_token']
      name = params['name']
      description = params['description']
      price = params['price'].to_i
      category_id = params['category_id'].to_i
      upload = params['image']

      unless upload.is_a?(Sinatra::IndifferentHash)
        halt_with_error 400, 'image error'
      end

      halt_with_error 422, 'csrf token error' if csrf_token != session['csrf_token']
      halt_with_error 400, 'category id error' if category_id < 0

      if name.nil? || description.nil? || price.zero? || category_id.zero?
        halt_with_error 400, 'all parameters are required'
      end

      if price < ITEM_MIN_PRICE || price > ITEM_MAX_PRICE
        halt_with_error 400, ITEM_PRICE_ERR_MSG
      end

      category = get_category_by_id(category_id)
      halt_with_error 400, 'Incorrect category ID' if category['parent_id'].zero?

      user = get_user
      halt_with_error 404, 'user not found' if user.nil?

      halt_with_error 500, 'image error' if upload['tempfile'].nil?
      img = upload['tempfile'].read

      ext = File.extname(upload['filename'])
      unless ['.jpg', '.jpeg', '.png', '.gif'].include?(ext)
        halt_with_error 400, 'unsupported image format error'
      end

      ext = '.jpg' if ext == '.jpeg'

      if HOSTNUM
        img_name = "#{HOSTNUM}/#{SecureRandom.hex(16)}#{ext}"
        File.open("/home/isucon/public.local/upload/#{img_name}", 'wb') do |f|
          f.write img
        end
      else
        img_name = "#{SecureRandom.hex(16)}#{ext}"
        File.open("#{settings.root}/public/upload/#{img_name}", 'wb') do |f|
          f.write img
        end
      end


      db.query('BEGIN')

      seller = db.xquery('SELECT * FROM `users` WHERE `id` = ?', user['id']).first
      if seller.nil?
        halt_with_error 404, 'user not found'
      end
      seller_stats = db.xquery('SELECT * FROM `user_stats` WHERE `user_id` = ? LOCK IN SHARE MODE', user['id']).first

      begin
        db.xquery('INSERT INTO `items` (`seller_id`, `status`, `name`, `price`, `description`,`image_name`,`category_id`) VALUES (?, ?, ?, ?, ?, ?, ?)', seller['id'], ITEM_STATUS_ON_SALE, name, price, description, img_name, category['id'])
      rescue
        db.query('ROLLBACK')
        raise
      end

      item_id = db.last_id

      now = Time.now
      begin
        db.xquery('UPDATE `user_stats` SET `num_sell_items` = ?, `last_bump` = ? WHERE `user_id` = ?', seller_stats['num_sell_items'] + 1, now, seller['id'])
      rescue
        db.query('ROLLBACK')
        raise
      end

      db.query('COMMIT')

      purge_category(category)
      purge_user(seller)

      { 'id' => item_id }.to_json
    end

    # postShip
    post '/ship' do
      csrf_token = body_params['csrf_token']
      item_id = body_params['item_id'].to_i

      halt_with_error 422, 'csrf token error' if csrf_token != session['csrf_token']

      seller = get_user
      halt_with_error 404, 'seller not found' if seller.nil?

      transaction_evidence = db.xquery('SELECT * FROM `transaction_evidences` WHERE `item_id` = ?', item_id).first
      halt_with_error 404, 'transaction_evidences not found' if transaction_evidence.nil?

      halt_with_error 403, '権限がありません' if transaction_evidence['seller_id'] != seller['id']

      db.query('BEGIN')

      begin
        item = db.xquery('SELECT * FROM `items` WHERE `id` = ? FOR UPDATE', item_id).first

        if item.nil?
          db.query('ROLLBACK')
          halt_with_error 404, 'item not found'
        end
      rescue => e
        puts e.full_message
        db.query('ROLLBACK')
        halt_with_error 500, 'db error'
      end

      if item['status'] != ITEM_STATUS_TRADING
        db.query('ROLLBACK')
        halt_with_error 403, '商品が取引中ではありません'
      end

      begin
        transaction_evidence = db.xquery('SELECT * FROM `transaction_evidences` WHERE `id` = ? LOCK IN SHARE MODE', transaction_evidence['id']).first

        if transaction_evidence.nil?
          db.query('ROLLBACK')
          halt_with_error 404, 'transaction_evidences not found'
        end
      rescue => e
        puts e.full_message
        db.query('ROLLBACK')
        halt_with_error 500, 'db error'
      end

      if transaction_evidence['status'] != TRANSACTION_EVIDENCE_STATUS_WAIT_SHIPPING
        db.query('ROLLBACK')
        halt_with_error 403, '準備ができていません'
      end

      begin
        shipping = db.xquery('SELECT * FROM `shippings` WHERE `transaction_evidence_id` = ? LOCK IN SHARE MODE', transaction_evidence['id']).first

        if shipping.nil?
          db.query('ROLLBACK')
          halt_with_error 404, 'shippings not found'
        end
      rescue => e
        puts e.full_message
        db.query('ROLLBACK')
        halt_with_error 500, 'db error'
      end

      begin
        img = api_client.shipment_request(get_shipment_service_url, shipping['reserve_id'])
      rescue => e
        puts e.full_message
        db.query('ROLLBACK')
        halt_with_error 500, 'failed to request to shipment service'
      end

      begin
        db.xquery('UPDATE `shippings` SET `status` = ?, `image_name` = ?,  `updated_at` = ? WHERE `transaction_evidence_id` = ?', SHIPPINGS_STATUS_WAIT_PICKUP, "#{HOSTNUM}/", Time.now, transaction_evidence['id'])
      rescue => e
        puts e.full_message
        db.query('ROLLBACK')
        halt_with_error 500, 'db error'
      end
      File.open("/home/isucon/public.local/upload/#{HOSTNUM}/tx_#{transaction_evidence['id']}.png", 'wb') do |io|
        io.write img
      end

      db.query('COMMIT')
      purge_item(item)

      response = {
        'path' => "/transactions/#{transaction_evidence['id']}.png",
        'reserve_id' => shipping['reserve_id']
      }

      response.to_json
    end

    # postShipDone
    post '/ship_done' do
      csrf_token = body_params['csrf_token']
      item_id = body_params['item_id'].to_i

      halt_with_error 422, 'csrf token error' if csrf_token != session['csrf_token']

      seller = get_user
      halt_with_error 404, 'seller not found' if seller.nil?

      transaction_evidence = db.xquery('SELECT * FROM `transaction_evidences` WHERE `item_id` = ?', item_id).first
      halt_with_error 404, 'transaction_evidence not found' if transaction_evidence.nil?

      if transaction_evidence['seller_id'] != seller['id']
        halt_with_error 403, '権限がありません'
      end

      db.query('BEGIN')

      begin
        item = db.xquery('SELECT * FROM `items` WHERE `id` = ? FOR UPDATE', item_id).first

        if item.nil?
          db.query('ROLLBACK')
          halt_with_error 404, 'items not found'
        end
      rescue => e
        puts e.full_message
        db.query('ROLLBACK')
        halt_with_error 500, 'db error'
      end

      if item['status'] != ITEM_STATUS_TRADING
        db.query('ROLLBACK')
        halt_with_error 403, '商品が取引中ではありません'
      end

      begin
        transaction_evidence = db.xquery('SELECT * FROM `transaction_evidences` WHERE `id` = ? LOCK IN SHARE MODE', transaction_evidence['id']).first

        if transaction_evidence.nil?
          db.query('ROLLBACK')
          halt_with_error 404, 'transaction_evidences not found'
        end
      rescue => e
        puts e.full_message
        db.query('ROLLBACK')
        halt_with_error 500, 'db error'
      end

      if transaction_evidence['status'] != TRANSACTION_EVIDENCE_STATUS_WAIT_SHIPPING
        halt_with_error 403, '準備ができていません'
      end

      begin
        shipping = db.xquery('SELECT * FROM `shippings` WHERE `transaction_evidence_id` = ? LOCK IN SHARE MODE', transaction_evidence['id']).first

        if shipping.nil?
          db.query('ROLLBACK')
          halt_with_error 404, 'shippings not found'
        end
      rescue => e
        puts e.full_message
        db.query('ROLLBACK')
        halt_with_error 500, 'db error'
      end

      begin
        ssr = api_client.shipment_status(get_shipment_service_url, shipping['reserve_id'])
      rescue => e
        puts e.full_message
        db.query('ROLLBACK')
        halt_with_error 500, 'failed to request to shipment service'
      end

      if !(ssr['status'] == SHIPPINGS_STATUS_SHIPPING || ssr['status'] == SHIPPINGS_STATUS_DONE)
        db.query('ROLLBACK')
        halt_with_error 403, 'shipment service側で配送中か配送完了になっていません'
      end

      begin
        db.xquery('UPDATE `shippings` SET `status` = ?, `updated_at` = ? WHERE `transaction_evidence_id` = ?', ssr['status'], Time.now, transaction_evidence['id'])
      rescue => e
        puts e.full_message
        db.query('ROLLBACK')
        halt_with_error 500, 'db error'
      end

      begin
        db.xquery('UPDATE `transaction_evidences` SET `status` = ?, `updated_at` = ? WHERE `id` = ?', TRANSACTION_EVIDENCE_STATUS_WAIT_DONE, Time.now, transaction_evidence['id'])
      rescue => e
        puts e.full_message
        db.query('ROLLBACK')
        halt_with_error 500, 'db error'
      end


      db.query('COMMIT')
      purge_item(item)

      response = {
        transaction_evidence_id: transaction_evidence['id']
      }

      response.to_json
    end

    # postComplete
    post '/complete' do
      csrf_token = body_params['csrf_token']
      item_id = body_params['item_id'].to_i

      halt_with_error 422, 'csrf token error' if csrf_token != session['csrf_token']

      buyer = get_user
      halt_with_error 404, 'buyer not found' if buyer.nil?

      transaction_evidence = db.xquery('SELECT * FROM `transaction_evidences` WHERE `item_id` = ?', item_id).first
      halt_with_error 404, 'transaction_evidence not found' if transaction_evidence.nil?

      if transaction_evidence['buyer_id'] != buyer['id']
        halt_with_error 403, '権限がありません'
      end

      db.query('BEGIN')

      begin
        item = db.xquery('SELECT * FROM `items` WHERE `id` = ? FOR UPDATE', item_id).first

        if item.nil?
          db.query('ROLLBACK')
          halt_with_error 404, 'items not found'
        end
      rescue => e
        puts e.full_message
        db.query('ROLLBACK')
        halt_with_error 500, 'db error'
      end

      if item['status'] != ITEM_STATUS_TRADING
        db.query('ROLLBACK')
        halt_with_error 403, '商品が取引中ではありません'
      end

      begin
        transaction_evidence = db.xquery('SELECT * FROM `transaction_evidences` WHERE `item_id` = ? LOCK IN SHARE MODE', item_id).first

        if transaction_evidence.nil?
          db.query('ROLLBACK')
          halt_with_error 404, 'transaction_evidences not found'
        end
      rescue => e
        puts e.full_message
        db.query('ROLLBACK')
        halt_with_error 500, 'db error'
      end

      if transaction_evidence['status'] != TRANSACTION_EVIDENCE_STATUS_WAIT_DONE
        db.query('ROLLBACK')
        halt_with_error 403, '準備ができていません'
      end

      begin
        shipping = db.xquery('SELECT * FROM `shippings` WHERE `transaction_evidence_id` = ? LOCK IN SHARE MODE', transaction_evidence['id']).first

        if shipping.nil?
          db.query('ROLLBACK')
          halt_with_error 404, 'shippings not found'
        end
      rescue => e
        puts e.full_message
        db.query('ROLLBACK')
        halt_with_error 500, 'db error'
      end

      begin
        ssr = api_client.shipment_status(get_shipment_service_url, shipping['reserve_id'])
      rescue => e
        puts e.full_message
        db.query('ROLLBACK')
        halt_with_error 500, 'failed to request to shipment service'
      end

      if ssr['status'] != SHIPPINGS_STATUS_DONE
        db.query('ROLLBACK')
        halt_with_error 400, 'shipment service側で配送完了になっていません'
      end

      begin
        db.xquery('UPDATE `shippings` SET `status` = ?, `updated_at` = ? WHERE `transaction_evidence_id` = ?', SHIPPINGS_STATUS_DONE, Time.now, transaction_evidence['id'])
      rescue => e
        puts e.full_message
        db.query('ROLLBACK')
        halt_with_error 500, 'db error'
      end

      begin
        db.xquery('UPDATE `transaction_evidences` SET `status` = ?, `updated_at` = ? WHERE `id` = ?', TRANSACTION_EVIDENCE_STATUS_DONE, Time.now, transaction_evidence['id'])
      rescue => e
        puts e.full_message
        db.query('ROLLBACK')
        halt_with_error 500, 'db error'
      end

      begin
        db.xquery('UPDATE `items` SET `status` = ?, `updated_at` = ? WHERE `id` = ?', ITEM_STATUS_SOLD_OUT, Time.now, item_id)
      rescue => e
        puts e.full_message
        db.query('ROLLBACK')
        halt_with_error 500, 'db error'
      end

      db.query('COMMIT')
      purge_item(item)

      response = {
        transaction_evidence_id: transaction_evidence['id']
      }

      response.to_json
    end

    # getQRCode
    get '/transactions/:transaction_evidence_id.png' do
      transaction_evidence_id = params['transaction_evidence_id'].to_i

      seller = get_user
      halt_with_error 404, 'seller not found' if seller.nil?

      transaction_evidence = db.xquery('SELECT * FROM `transaction_evidences` WHERE `id` = ?', transaction_evidence_id).first
      halt_with_error 404, 'transaction_evidences not found' if transaction_evidence.nil?

      if transaction_evidence['seller_id'] != seller['id']
        halt_with_error 403, '権限がありません'
      end

      shipping = db.xquery('SELECT * FROM `shippings` WHERE `transaction_evidence_id` = ?', transaction_evidence['id']).first
      halt_with_error 404, 'shippings not found' if shipping.nil?

      if shipping['status'] != SHIPPINGS_STATUS_WAIT_PICKUP && shipping != SHIPPINGS_STATUS_SHIPPING
        halt_with_error 403, 'qrcode not available'
      end

      halt_with_error 500, 'empty qrcode image' if !shipping['image_name'] || shipping['image_name'].empty?

      content_type 'image/png'
      headers 'X-Accel-Redirect' => "/_upload/#{shipping['image_name']}tx_#{transaction_evidence_id}.png"
    end

    # postBump
    post '/bump' do
      csrf_token = body_params['csrf_token']
      item_id = body_params['item_id']

      halt_with_error 422, 'csrf token error' if csrf_token != session['csrf_token']

      user = get_user
      halt_with_error 404, 'user not found' if user.nil?

      db.query('BEGIN')

      begin
        target_item = db.xquery('SELECT * FROM `items` WHERE `id` = ? FOR UPDATE', item_id).first

        if target_item.nil?
          db.query('ROLLBACK')
          halt_with_error 404, 'item not found'
        end
      rescue => e
        puts e.full_message
        db.query('ROLLBACK')
        halt_with_error 500, 'db error'
      end

      if target_item['seller_id'] != user['id']
        db.query('ROLLBACK')
        halt_with_error 403, '自分の商品以外は編集できません'
      end

      begin
        seller = db.xquery('SELECT * FROM `users` WHERE `id` = ? LOCK IN SHARE MODE', user['id']).first

        if seller.nil?
          db.query('ROLLBACK')
          halt_with_error 404, 'user not found'
        end
      rescue => e
        puts e.full_message
        db.query('ROLLBACK')
        halt_with_error 500, 'db error'
      end

      now = Time.now
      if seller['last_bump'].to_i + BUMP_CHARGE_SECONDS > now.to_i
        db.query('ROLLBACK')
        halt_with_error 403, 'Bump not allowed'
      end

      begin
        db.xquery('UPDATE `items` SET `created_at` = ?, `updated_at` = ? WHERE id = ?', now, now, target_item['id'])
      rescue => e
        puts e.full_message
        db.query('ROLLBACK')
        halt_with_error 500, 'db error'
      end

      begin
        db.xquery('UPDATE `user_stats` SET `last_bump` = ? WHERE user_id = ?', now, seller['id'])
      rescue => e
        puts e.full_message
        db.query('ROLLBACK')
        halt_with_error 500, 'db error'
      end

      begin
        target_item = db.xquery('SELECT * FROM `items` WHERE `id` = ?', item_id).first
      rescue => e
        puts e.full_message
        db.query('ROLLBACK')
        halt_with_error 500, 'db error'
      end

      db.query('COMMIT')
      purge_item(target_item)

      response = {
        'item_id' => target_item['id'],
        'item_price' => target_item['price'],
        'item_created_at' => target_item['created_at'].to_i,
        'item_updated_at' => target_item['updated_at'].to_i
      }

      response.to_json
    end

    # getSettings
    get '/settings' do
      csrf_token = session['csrf_token']
      user = get_user

      response = {}
      response['csrf_token'] = csrf_token
      response['user'] = user unless user.nil?
      response['payment_service_url'] = get_payment_service_url

      response['categories'] = CATEGORIES.values

      response.to_json
    end

    # postLogin
    post '/login' do
      account_name = body_params['account_name'] || ''
      password = body_params['password'] || ''

      if account_name == '' || password == ''
        halt_with_error 400, 'all parameters are required'
      end

      user = db.xquery('SELECT * FROM `users` WHERE `account_name` = ?', account_name).first

      if user.nil? || BCrypt::Password.new(user['hashed_password']) != password
        halt_with_error 401, 'アカウント名かパスワードが間違えています'
      end

      session['user_id'] = user['id']
      session['csrf_token'] = SecureRandom.hex(20)

      user.to_json
    end

    # postRegister
    post '/register' do
      account_name = body_params['account_name'] || ''
      address = body_params['address'] || ''
      password = body_params['password'] || ''

      if account_name == '' || password == '' || address == ''
        halt_with_error 500, 'all parameters are required'
      end

      hashed_password = BCrypt::Password.create(password, 'cost' => BCRYPT_COST)

      begin
        db.query('BEGIN')
        db.xquery('INSERT INTO `users` (`account_name`, `hashed_password`, `address`) VALUES (?, ?, ?)', account_name, hashed_password, address)
        user_id = db.last_id
        db.xquery('INSERT INTO `user_stats` (`account_name`, `hashed_password`, `address`, `user_id`) VALUES (?)', account_name, hashed_password, address, user_id)
      rescue => e
        puts e.full_message
        db.query('ROLLBACK')
        raise
      end

      user = {
        'id' => user_id,
        'account_name' => account_name,
        'address' => address
      }

      session['user_id'] = user_id
      session['csrf_token'] = SecureRandom.hex(20)

      user.to_json
    end

    # getReports
    get '/reports.json' do
      transaction_evidences = db.xquery('SELECT * FROM `transaction_evidences` WHERE `id` > 15007')

      response = transaction_evidences.map do |transaction_evidence|
        {
          'id' => transaction_evidence['id'],
          'seller_id' => transaction_evidence['seller_id'],
          'buyer_id' => transaction_evidence['buyer_id'],
          'status' => transaction_evidence['status'],
          'item_id' => transaction_evidence['item_id'],
          'item_name' => transaction_evidence['item_name'],
          'item_price' => transaction_evidence['item_price'],
          'item_description' => transaction_evidence['item_description'],
          'item_category_id' => transaction_evidence['item_category_id'],
          'item_root_category_id' => transaction_evidence['item_root_category_id']
        }
      end

      response.to_json
    end

    # Frontend

    def get_index
      send_file File.join(settings.public_folder, 'index.html')
    end

    get '/' do
      get_index
    end

    get '/login' do
      get_index
    end

    get '/register' do
      get_index
    end

    get '/timeline' do
      get_index
    end

    get '/categories/:category_id/items' do
      get_index
    end

    get '/sell' do
      get_index
    end

    get '/items/:item_id' do
      get_index
    end

    get '/items/:item_id/edit' do
      get_index
    end

    get '/items/:item_id/buy' do
      get_index
    end

    get '/buy/complete' do
      get_index
    end

    get '/transactions/:transaction_id' do
      get_index
    end

    get '/users/:user_id' do
      get_index
    end

    get '/users/setting' do
      get_index
    end

    get '/site/errortown' do
      raise "aaaaaaaaaaaaaaaaaa"
    end



    error Mysql2::Error do
      { 'error' => 'db error' }.to_json
    end

    error JSON::ParserError do
      { 'error' => 'json decode error' }.to_json
    end
  end
end
