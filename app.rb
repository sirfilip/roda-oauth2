require 'logger'
require 'roda'
require 'sequel'
require 'bcrypt'
require 'dry/schema'
require 'dry/monads'
require 'uuid'
require 'pundit'
require 'byebug'

include Dry::Monads[:result, :maybe]

DB = if ENV['RACK_ENV'] == 'test'
       Sequel.sqlite
     else
       Sequel.sqlite('db.sqlite')
     end

def log
  @logger ||= Logger.new(STDOUT)
end

DB.create_table?(:users) do
  primary_key :id
  String      :username, unique: true
  String      :email, unique: true
  String      :password
end

DB.create_table?(:clients) do
  primary_key :id
  Numeric     :user_id
  String      :name, unique: true
  String      :callback_url
  String      :client_id
  String      :client_secret
  add_unique_constraint [:client_id, :client_secret]
end

class Hasher
  def hash(secret)
    BCrypt::Password.create(secret)
  end

  def check(hash, secret)
    BCrypt::Password.new(hash) == secret
  end
end

class User < Sequel::Model(DB)
  def self.find_by(criteria)
    user = self.where(criteria).first
    if user
      Some(user)
    else
      None()
    end
  end
end

class Client < Sequel::Model(DB)
  def self.owned_by(user)
    self.where(user_id: user.id)
  end

  def self.find_by(criteria)
    client = self.where(criteria).first
    if client
      Some(client)
    else
      None()
    end
  end
end


# authorization
class Authorization
  def call(owner, record, action)
    if Pundit.policy!(owner, record).public_send(action)
      Success(:authorized)
    else
      Failure(:unauthorized)
    end
  end
end

class ClientPolicy
  def initialize(current_user, client)
    @current_user = current_user
    @client = client
  end
  def delete?
    @client.user_id == @current_user.id
  end
end

# features
module Feature
  module Register
    class Form
      Schema = Dry::Schema.Params do
        required(:username) {filled? & size?(5..25)}
        required(:email) { filled? & format?(/^[-a-zA-Z0-9_.+]+@[-a-zA-Z0-9]+\.[-a-zA-Z0-9.]+$/)}
        required(:password) { filled? & size?(6..64)}
      end

      def initialize(repo)
        @repo = repo
      end

      def submit(username, email, password)
        errors = Schema.call(username: username, email: email, password: password).errors(full: true).to_h.dup

        if errors[:username].nil?
          @repo.find_by(username: username).bind do
            errors[:username] = ['username is taken']
          end
        end

        if errors[:email].nil?
          @repo.find_by(email: email).bind do
            errors[:email] = ['email is taken']
          end
        end

        if errors.any?
          Failure[:validation_failure, errors]
        else
          Success()
        end
      end
    end

    class Service
      def initialize(form, repo, hasher)
        @form = form
        @repo = repo
        @hasher = hasher
      end

      def call(username, email, password)
        @form.submit(username, email, password).bind do
          password = @hasher.hash(password)
          Success(@repo.create(username: username, email: email, password: password))
        end
      end
    end
  end

  module Login
    class Form
      Schema = Dry::Schema.Params do 
        required(:username) { filled? }
        required(:password) { filled? }
      end

      def submit(params)
        if Schema.(params).errors(full: true).to_h.any?
          Failure(:wrong_username_and_password_combination)
        else
          Success()
        end
      end
    end

    class Service
      def initialize(form, repo, hasher)
        @form = form
        @repo = repo
        @hasher = hasher
      end

      def call(username, password)
        @form.submit({username: username, password: password}).bind do
          @repo.find_by(username: username).bind do |user|
            if @hasher.check(user.password, password)
              Success(user)
            else
              Failure(:wrong_username_and_password_combination)
            end
          end.or do
            Failure(:wrong_username_and_password_combination)
          end
        end
      end
    end
  end

  module CreateClient
    class Form

      def initialize(repo)
        @repo = repo
      end

      Schema = Dry::Schema.Params do
        required(:name) { filled? & str? & size?(2..255) }
        required(:callback_url) { filled? & str? & size?(5..255) }
      end

      def submit(params)
        errors = Schema.(params).errors(full: true).to_h
        unless errors[:name]
          @repo.find_by(name: params[:name]).bind do
            errors[:name] = [ 'name is already taken' ]
          end
        end

        unless errors[:callback_url]
          begin
            uri = URI.parse(params[:callback_url])
            unless uri.kind_of?(URI::HTTPS)
              errors[:callback_url] = [ 'callback_url is invalid' ]
            end
          rescue URI::InvalidURIError
            errors[:callback_url] = [ 'callback_url is invalid' ]
          end
        end
        
        if errors.any?
          Failure[:validation_failure, errors]
        else
          Success()
        end
      end
    end
    class Service
      def initialize(form, repo, uuidgen)
        @form = form
        @repo = repo
        @uuidgen = uuidgen
      end

      def call(user, name, callback_url)
        @form.submit({name: name, callback_url: callback_url}).bind do
          client_id = @uuidgen.generate
          client_secret = @uuidgen.generate
          Success(@repo.create(
            name: name, 
            callback_url: callback_url,
            client_id: client_id,
            client_secret: client_secret,
            user_id: user.id,
          ))
        end
      end
    end
  end

  module ListClients
    class Service
      def initialize(repo, owner)
        @repo = repo
        @owner = owner
      end

      def call
        Success(@repo.owned_by(@owner).all)
      end
    end
  end

  module DeleteClient
    class Service
      def initialize(repo, authorization, owner)
        @repo = repo
        @owner = owner
        @authorization = authorization
      end

      def call(client_id)
        @repo.find_by(id: client_id).bind do |client|
          @authorization.(@owner, client, :delete?).bind do
            client.delete
            Success()
          end
        end
      end
    end
  end
end

ENV['APP_SESSION_SECRET'] ||= 'super secret' * 64

class App < Roda
  plugin :render, escape: true
  plugin :public
  plugin :halt
  plugin :sessions, secret: ENV.delete('APP_SESSION_SECRET')
  plugin :flash


  route do |r|

    r.public 

    @success = flash['success']
    @warn = flash['warn']

    r.on 'register' do
      @title = 'Register'
      @errors = {}

      r.get do
        view('register/register')
      end

      r.post do
        repo = User
        form = Feature::Register::Form.new(repo)
        case Feature::Register::Service.new(form, repo, Hasher.new).(
          r.params['username'],
          r.params['email'],
          r.params['password'],
        )
          in Success(User => user)
            r.redirect '/login'
          in Failure[:validation_failure, errors]
            @errors = errors
            view('register/register')
          else
            log.warn("Unhandled case") 
            r.halt(500, 'Server Error')
          end
      end
    end

    r.on 'login' do
      @title = 'login'

      r.get do
        view('login/login')
      end

      r.post do
        case Feature::Login::Service.new(
          Feature::Login::Form.new, 
          User, 
          Hasher.new,
        ).(r.params['username'], r.params['password'])
          in Success(User => user) 
            r.session['auth_id'] = user.id
            r.redirect("/")
          in Failure(:wrong_username_and_password_combination)
            @error = 'Wrong username and password combo'
            view('login/login')
        else
          log.warn("login#post: unsupported branch")
          r.halt(500, 'Server Error')
        end
      end
    end

    current_user = r.session['auth_id'] && User.find(r.session['auth_id']).first
    unless current_user
      r.redirect('/login')
    end

    r.root do
      case Feature::ListClients::Service.new(Client, current_user).call
        in Success(*clients)
          @clients = clients
          view('clients/list')
      else
          log.warn("dashboard#get: unsupported branch")
          r.halt(500, 'Server Error')
      end
    end

    r.on 'clients' do
      r.get 'new' do
        @title = 'create client'
        view('clients/new')
      end

      r.on Integer do |client_id|
        r.get 'delete' do
          case Feature::DeleteClient::Service.new(Client, Authorization.new, current_user).(client_id)
            in Success
              flash['success'] = 'Client Deleted'
              r.redirect '/'
            else
              log.warn("client#delete: unsupported branch")
              r.halt(500, 'Server Error')
            end
        end
      end

      r.post do
        @title = 'create client'
        case Feature::CreateClient::Service.new(
          Feature::CreateClient::Form.new(Client),
          Client,
          UUID.new,
        ).call(current_user, r.params['name'], r.params['callback_url'])
          in Failure[:validation_failure, errors]
            @errors = errors
            view('clients/new')
          in Success(Client => client)
            flash['success'] = 'Client successfully created'
            r.redirect('/')
        else
          log.warn("Unknown branch")
          r.halt(500)
        end
      end
    end
  end
end
