require 'sinatra'
require 'sinatra/reloader' if development?
require 'tilt/erubis'
require 'sinatra/content_for'
require 'chartkick'
require 'bcrypt'
require 'net/http'
require 'json'
require 'yaml'
require 'redcarpet'
require 'pry'

ROOT = File.expand_path('..', __FILE__)

CURRENT_PRICES_API = 'https://min-api.cryptocompare.com/data/' \
  'pricemulti?fsyms=BTC,ETH&tsyms=USD'.freeze

TIME_OUT_SECONDS = (ENV['RACK_ENV'] == 'test' ? 2 : 1500)

CURRENCY_NAMES = {
  btc: 'Bitcoin',
  eth: 'Ether',
  usd: 'US Dollars'
}.freeze

configure do
  enable :sessions
  set :session_secret, 'secret'
  set :erb, escape_html: true
end

helpers do
  def user_signed_in?
    session[:signin] && !timed_out?
  end

  def format_usd(num)
    whole, decimal = format('%.2f', num).split('.')
    comma_sliced = whole.reverse.scan(/\d{3}|\d+/).join(',').reverse
    '$' + comma_sliced + '.' + decimal
  end

  def buy_link(buy_coin, for_coin)
    "href=/buy/#{for_coin}" unless buy_coin == for_coin
  end

  def sell_link(sell_coin, for_coin)
    "href=/sell/#{for_coin}" unless sell_coin == for_coin
  end

  def class_active_status(buy_coin, for_coin)
    "class='active'" if buy_coin == for_coin
  end
end

before do
  @users_data = YAML.load_file(user_data_file_path)

  sign_user_out_if_idle
end

class Transaction
  attr_reader :type, :coin_amount, :usd_amount, :time

  def initialize(type, coin, coin_amount, usd_amount)
    @type = type
    @coin = coin
    @coin_amount = coin_amount
    @usd_amount = usd_amount
    @time = Time.now
  end

  def coin
    @coin.upcase
  end

  def price
    usd_amount / coin_amount
  end
end

def parse_api(url)
  uri = URI(url)
  response = Net::HTTP.get(uri)
  JSON.parse(response)
end

def cypto_compare_histohour_api(coin, limit, aggregate)
  "https://min-api.cryptocompare.com/data/histohour?fsym=#{coin.upcase}" \
  "&tsym=USD&limit=#{limit}&aggregate=#{aggregate}&e=CCCAGG"
end

def fetch_histohour_chart_data(coin, limit:, aggregate:)
  begin
    url = cypto_compare_histohour_api(coin, limit, aggregate)
    raw_data = parse_api(url)
    cache_historical_data(coin, raw_data)
  rescue SocketError, Errno
    raw_data = YAML.load_file('data/cache_hist.yml')[coin]
  end

  parse_historical_data(raw_data)
end

def cache_historical_data(coin, raw_data)
  cache_file = 'data/cache_hist.yml'
  cache_data = YAML.load_file(cache_file)

  cache_data[coin] = raw_data
  File.write(cache_file, cache_data.to_yaml)
end

def cache_current_prices(current_prices)
  File.write('data/cache_prices.yml', current_prices.to_yaml)
end

def fetch_current_prices
  begin
    session[:offline] = false
    current_prices = parse_api(CURRENT_PRICES_API)

    cache_current_prices(current_prices)
    current_prices
  rescue SocketError, Errno
    session[:offline] = true
    YAML.load_file('data/cache_prices.yml')
  end
end

def user_data_file_path
  if ENV['RACK_ENV'] == 'test'
    'test/data/users_data.yml'
  else
    'data/users_data.yml'
  end
end

def credential_invalids(username, password, agreed = nil)
  {
    'Please enter a username.' => username.empty?,
    'Username must not contain spaces.' => username.include?(' '),
    'Username too long.' => username.size > 30,
    "Username '#{username}' is unavailable." => @users_data.key?(username),
    'Password too short.' => (1..3).cover?(password.size),
    'Password must contain a non-space character.' => password.strip.empty?,
    'Please accept the user agreement.' => agreed != 'true'
  }
end

def new_password_invalids(password)
  {
    'New password too short.' => (1..3).cover?(password.size),
    'New password must contain a non-space character.' => 
      password.strip.empty?
  }
end

def build_error_message(errors)
  errors.select { |_, condition| condition }
        .keys
        .join('<br />')
end

def create_new_user_data(password)
  sign_up_bonus = rand(8999..19_999)
  new_trx = Transaction.new(:deposit, 'USD', sign_up_bonus, sign_up_bonus)
  {
    password: BCrypt::Password.create(password).to_s,
    created: Time.now.to_s,
    new_user: true,
    balances: { btc: 0, eth: 0, usd: sign_up_bonus },
    transactions: [new_trx]
  }
end

def credentials_match?(username, password)
  return false unless @users_data.key?(username)

  stored_password = @users_data[username][:password]
  BCrypt::Password.new(stored_password) == password
end

def sign_user_in(username)
  session[:signin] = { username: username, time: Time.now }
end

def reset_idle_time
  session[:signin][:time] = Time.now
end

def sign_user_out
  session.delete(:signin)
end

def timed_out?
  session_idle_seconds = Time.now - session[:signin][:time]
  session_idle_seconds > TIME_OUT_SECONDS
end

def require_user_signed_in
  unless user_signed_in?
    session[:failure] ||= 'Please sign-in to continue.'
    redirect '/signin'
  end
end

def sign_user_out_if_idle
  if session[:signin] && timed_out?
    sign_user_out
    session[:failure] = 'You have been logged out due to inactivity.'
  end
end

def usd_funded_message
  if signed_in_user_data[:new_user]
    'Sign-up bonus! Your account was funded ' \
    "<b>+#{format_usd(user_balances[:usd])}</b>.<br />"
  end
end

def sign_in_message
  "#{usd_funded_message}" \
  "Signed in as '#{session[:signin][:username]}'.<br />" \
  "<em>Timestamp: #{session[:signin][:time]}.</em>"
end

def write_new_user_data!(username, password)
  @users_data[username] = create_new_user_data(password)
  update_users_data!
end

def update_users_data!
  File.write(user_data_file_path, @users_data.to_yaml)
end

def signed_in_user_data
  username = session[:signin][:username]
  @users_data[username]
end

def user_balances
  require_user_signed_in
  signed_in_user_data[:balances]
end

def spot_price_range(usd_amt, coin_amt, coin)
  current_coin_price = fetch_current_prices[coin]['USD']
  (0.995..1.005).cover?(current_coin_price / (usd_amt / coin_amt))
end

def invalid_numbers(*numbers)
  numbers.any? { |num| num < 0 || !num.is_a?(Numeric) }
end

def purchase_validation_errors(usd_amt, coin_amt, coin)
  {
    'Price adjusted. Please try again.' =>
      !spot_price_range(usd_amt, coin_amt, coin),
    "Not enough funds to purchase #{coin_amt} #{coin}." =>
      (usd_amt > user_balances[:usd]),
    'Invalid inputs. Please try again.' => invalid_numbers(usd_amt, coin_amt),
    'Minimum purchase of $1 is required.' => usd_amt < 1
  }
end

def sell_validation_errors(usd_amt, coin_amt, coin)
  {
    'Price adjusted. Please try again.' =>
      !spot_price_range(usd_amt, coin_amt, coin),
    "You don't have enough #{coin} to sell." =>
      (coin_amt > user_balances[coin.downcase.to_sym]),
    'Invalid inputs. Please try again.' => invalid_numbers(usd_amt, coin_amt),
    "Minimum sale amount of 0.000001 #{coin} is required." =>
      coin_amt < 0.000001
  }
end

def falsify_new_user_status!
  signed_in_user_data[:new_user] = false
  update_users_data!
end

def create_transaction(type, coin, coin_amt, usd_amt)
  new_trx = Transaction.new(type, coin, coin_amt, usd_amt)
  signed_in_user_data[:transactions] << new_trx
end

def format_portfolio_chart_data(portfolio_data, counter_values)
  portfolio_data.map do |symbol, balance|
    counter_value = balance * counter_values[symbol].round(2)
    [symbol.upcase, counter_value]
  end.to_h
end

def sort_trx_by_most_recent
  signed_in_user_data[:transactions].sort_by(&:time)
                                    .reverse
end

def unix_time_to_date(unix_time)
  Time.strptime(unix_time.to_s, '%s').to_s
end

def parse_historical_data(raw_data)
  raw_data['Data'].map do |data|
    [unix_time_to_date(data['time']), data['close']]
  end.to_h
end

not_found do
  erb :not_found
end

get '/' do
  redirect '/dashboard' if user_signed_in?
  erb :index
end

get '/charts' do
  @historical_bpi = fetch_histohour_chart_data('BTC', limit: 180, aggregate: 4)
  @min_btc_price, @max_btc_price = @historical_bpi.values.minmax

  @historical_eth = fetch_histohour_chart_data('ETH', limit: 180, aggregate: 4)
  @min_eth_price, @max_eth_price = @historical_eth.values.minmax

  current_prices = fetch_current_prices
  @current_btc_price = current_prices['BTC']['USD']
  @current_eth_price = current_prices['ETH']['USD']

  erb :charts
end

get '/signup' do
  redirect '/dashboard' if user_signed_in?
  erb :signup
end

post '/user/signup' do
  @username = params[:username]
  @password = params[:password]
  @agreed = params[:agreed]
  new_username = @username.strip

  errors = credential_invalids(new_username, @password, @agreed)

  if errors.none? { |_, condition| condition }
    write_new_user_data!(@username, @password)

    sign_user_in(@username)
    session[:success] = sign_in_message
    falsify_new_user_status!

    redirect '/dashboard'
  else
    session[:failure] = build_error_message(errors)
    status 422
    erb :signup
  end
end

get '/signin' do
  redirect '/' if user_signed_in?
  erb :signin
end

post '/user/signin' do
  sign_user_out

  @username = params[:username].strip
  @password = params[:password]

  if credentials_match?(@username, @password)
    sign_user_in(@username)
    session[:success] = sign_in_message
    redirect '/dashboard'
  else
    session[:failure] = 'Invalid credentials. Please try again.'
    status 422
    erb :signin
  end
end

get '/dashboard' do
  require_user_signed_in
  reset_idle_time

  @portfolio = signed_in_user_data[:balances]
  current_prices = fetch_current_prices

  @counter_values = {
    btc: current_prices['BTC']['USD'],
    eth: current_prices['ETH']['USD'],
    usd: 1
  }

  @portfolio_chart_data =
    format_portfolio_chart_data(@portfolio, @counter_values)

  @transactions = sort_trx_by_most_recent

  erb :dashboard
end

post '/user/signout' do
  sign_user_out
  session.delete(:failure) if session[:failure]
  redirect '/'
end

get '/buy' do
  require_user_signed_in
  redirect '/buy/btc'
end

get '/buy/:coin' do
  current_prices = fetch_current_prices
  require_user_signed_in
  reset_idle_time

  @coin = params[:coin]

  @current_btc_price = current_prices['BTC']['USD']
  @current_eth_price = current_prices['ETH']['USD']

  @usd_balance = user_balances[:usd]

  erb :buy
end

post '/user/buy/:coin' do
  require_user_signed_in
  reset_idle_time

  coin = params[:coin]

  @usd_amount = params[:usd_amount].to_f
  @coin_amount = params[:coin_amount].to_f
  errors = purchase_validation_errors(@usd_amount, @coin_amount, coin.upcase)

  if errors.none? { |_, condition| condition }
    session[:success] = 'You have successfully purchased' \
      " #{@coin_amount} #{coin.upcase}!"

    signed_in_user_data[:balances][:usd] -= @usd_amount.round(2)
    signed_in_user_data[:balances][coin.to_sym] += @coin_amount
    create_transaction(:buy, coin, @coin_amount, @usd_amount)
    update_users_data!

    redirect '/dashboard'
  else
    session[:failure] = build_error_message(errors)
    redirect "/buy/#{coin}"
  end
end

get '/sell' do
  require_user_signed_in
  redirect '/sell/btc'
end

get '/sell/:coin' do
  current_prices = fetch_current_prices
  require_user_signed_in
  reset_idle_time

  @coin = params[:coin]

  @current_btc_price = current_prices['BTC']['USD']
  @current_eth_price = current_prices['ETH']['USD']

  @coin_balance = signed_in_user_data[:balances][@coin.to_sym]

  erb :sell
end

post '/user/sell/:coin' do
  require_user_signed_in
  reset_idle_time

  coin = params[:coin]

  @usd_amount = params[:usd_amount].to_f
  @coin_amount = params[:coin_amount].to_f
  errors = sell_validation_errors(@usd_amount, @coin_amount, coin.upcase)

  if errors.none? { |_, condition| condition }
    session[:success] = "You have successfully sold #{@coin_amount} " \
      "#{coin.upcase}. Account value +#{format_usd(@usd_amount)}."

    signed_in_user_data[:balances][:usd] += @usd_amount.round(2)
    signed_in_user_data[:balances][coin.to_sym] -= @coin_amount
    create_transaction(:sell, coin, @coin_amount, -@usd_amount)
    update_users_data!

    redirect '/dashboard'
  else
    session[:failure] = build_error_message(errors)
    status 422
    redirect "/sell/#{coin}"
  end
end

get '/settings' do
  require_user_signed_in
  reset_idle_time

  erb :settings
end

post '/user/update-password' do
  require_user_signed_in
  reset_idle_time
  username = session[:signin][:username]

  @old_password = params[:old_password]
  new_password = params[:new_password]

  errors = new_password_invalids(new_password)

  if credentials_match?(username, @old_password) &&
     errors.none? { |_, condition| condition }

    signed_in_user_data[:password] = BCrypt::Password.create(new_password).to_s

    update_users_data!

    session[:success] = 'Password successfully updated!'
    redirect '/dashboard'
  else
    session[:failure] = build_error_message(errors)
    if session[:failure].empty?
      session[:failure] = 'Invalid password. Please try again'
    end

    status 422
    erb :settings
  end
end

post '/user/delete' do
  require_user_signed_in
  reset_idle_time
  username = session[:signin][:username]

  @password = params[:password]

  if credentials_match?(username, @password)
    sign_user_out
    @users_data.delete(username)
    update_users_data!

    session[:success] = "User account <em>'#{username}'</em> has been deleted!"
    redirect '/'
  else
    session[:failure] = 'Invalid password. Please try again'
    status 422
    erb :settings
  end
end

get '/agreement' do
  @markdown = Redcarpet::Markdown.new(Redcarpet::Render::HTML)
  @user_agreement = File.read('data/agreement.md')

  erb :agreement
end
