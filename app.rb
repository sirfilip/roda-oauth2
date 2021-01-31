require 'logger'
require 'roda'
require 'sequel'
require 'bcrypt'
require 'dry/schema'
require 'dry/monads'
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
  String :username, unique: true
  String :email, unique: true
  String :password
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
end

class App < Roda
  plugin :render, escape: true
  plugin :public
  plugin :halt

  route do |r|
    r.public 

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

    r.root do
      "It works!"
    end
  end
end
