require 'minitest/autorun'
require 'capybara/dsl'

ENV['RACK_ENV'] = 'test'

require './app'

def register_svc
  repo = User
  form = Feature::Register::Form.new(repo)
  Feature::Register::Service.new(form, repo, Hasher.new)
end

def login_svc
  repo = User
  form = Feature::Login::Form.new
  Feature::Login::Service.new(form, repo, Hasher.new)
end

def add_client_svc
  repo = Client
  form = Feature::AddClient::Form.new(repo)
  Feature::CreateClient::Service.new(form, repo, UUID.new)
end

describe 'Features' do
  describe 'Register' do
    before do
      DB[:users].delete
      @user = User.create(username: 'tester', email: 'test@example.com', password: 'testpassword')
    end


    tests = {
      'nil params' => {
        :given => -> (user) {
          {}
        },
        :want => Failure[:validation_failure, {
          :username => ['username must be filled'],
          :email => ['email must be filled'],
          :password => ['password must be filled'],
        }],
      },
      'blank params' => {
        :given => -> (user) {
          {
            'username' => '',
            'email' => '',
            'password' => '',
          }
        },
        :want => Failure([:validation_failure, {
          :username => ['username must be filled'],
          :email => ['email must be filled'],
          :password => ['password must be filled'],
        }]),
      },
      'uniqueness' => {
        :given => -> (user) {
          {
            'username' => user.username,
            'email' => user.email,
            'password' => user.password,
          }
        },
        :want => Failure([:validation_failure, {
          :username => ['username is taken'],
          :email => ['email is taken'],
        }]),
      },
    }
    tests.each do |title, t|
      it title do
        given = t[:given].call(@user)
        got = register_svc.call(given['username'], given['email'], given['password'])
        assert got == t[:want]
      end
    end
  end

  describe 'Login' do

    before do
      DB[:users].delete
      @user = register_svc.call('username', 'username@example.com', 'password').value!
    end

    tests = {
      'successfull login' => {
        given: {
          username: 'username',
          password: 'password',
        },
        want: -> (user) {
          Success(user)
        }
      },
      'no params provided' => {
        given: {},
        want: -> (user) {
          Failure(:wrong_username_and_password_combination)
        }
      },
      'wrong username and password' => {
        given: {
          username: 'other',
          password: 'other',
        },
        want: -> (user) {
          Failure(:wrong_username_and_password_combination)
        }
      },
      'correct username but wrong password' => {
        given: {
          username: 'username',
          password: 'other',
        },
        want: -> (user) {
          Failure(:wrong_username_and_password_combination)
        }
      },
      'correct password but wrong username' => {
        given: {
          username: 'other',
          password: 'password',
        },
        want: -> (user) {
          Failure(:wrong_username_and_password_combination)
        }
      },
    }
    tests.each do |title, test|
      it title do
        got = login_svc.(test[:given][:username], test[:given][:password])
        assert got == test[:want].(@user)
      end
    end
  end
  

end

Capybara.app = App.app

describe App do
  include Capybara::DSL

  after { Capybara.reset_sessions! }

  describe 'register' do
    before do
      DB[:users].delete
    end

    it 'has the right form fields' do
      visit '/register'
      assert page.has_selector?('input[name=username]'), 'has the username field'
      assert page.has_selector?('input[name=email]'), 'has the email field'
      assert page.has_selector?('input[name=password]'), 'has the password field'
    end

    describe 'validation' do
      tests = {
        'blank fields' => {
          got: {
            username: '',
            email: '',
            password: '',
          },
          want: [
            'Username must be filled',
            'Email must be filled',
            'Password must be filled',
          ]
        },
      }
      tests.each do |title, t|
        it title do
          visit '/register'
          fill_in :username, with: t[:got][:username]
          fill_in :email, with: t[:got][:email]
          fill_in :password, with: t[:got][:password]
          click_on 'Register'
          t[:want].each do |error|
            assert page.has_content?(error)
          end
        end
      end
    end

    it 'registers' do
      visit '/register'
      fill_in :username, with: 'testuser'
      fill_in :email, with: 'testemail@example.com'
      fill_in :password, with: 'passwordtime'
      click_on 'Register'
      assert page.has_current_path?('/login')
    end
  end

  describe 'login' do
    before do
      DB[:users].delete
      register_svc.call('username', 'username@example.com', 'password').value!
    end

    it 'has the right form fields' do
      visit '/login'
      assert page.has_selector?('input[name=username]'), 'has the username field'
      assert page.has_selector?('input[name=password]'), 'has the password field'
    end

    describe 'failure' do
      tests = {
        'blank fields' => {
          got: {
            username: '',
            password: '',
          },
          want: 'Wrong username and password combo'
        },
        'wrong username' => {
          got: {
            username: 'wrong',
            password: 'password',
          },
          want: 'Wrong username and password combo'
        },
        'wrong password' => {
          got: {
            username: 'username',
            password: 'wrong',
          },
          want: 'Wrong username and password combo'
        },
      }
      tests.each do |title, t|
        it title do
          visit '/login'
          fill_in :username, with: t[:got][:username]
          fill_in :password, with: t[:got][:password]
          click_on 'Login'
          assert page.has_content?(t[:want])
        end
      end
    end

    it 'success' do
      visit '/login'
      fill_in :username, with: 'username'
      fill_in :password, with: 'password'
      click_on 'Login'
      assert page.has_current_path?('/')
    end
  end

  describe 'dasboard' do
    describe 'unauthorized access' do
      it 'redirects to /login' do
        visit '/'
        assert page.has_current_path?('/login')
      end
    end
    
    describe 'autorized' do
      before do
        DB[:users].delete
        visit '/register'
        fill_in :username, with: 'username'
        fill_in :email, with: 'username@example.com'
        fill_in :password, with: 'password'
        click_on 'Register'
        
        visit '/login'
        fill_in :username, with: 'username'
        fill_in :password, with: 'password'
        click_on 'Login'
        @current_user = User.find_by(username: 'username').value!
      end

      it 'shows the list of clients' do
      end

      describe 'create client' do
        it 'has the correct form elements' do
          visit '/clients/new'
          assert page.has_selector?('input[name=name]')
          assert page.has_selector?('input[name=callback_url]')
        end

        describe 'validation' do
          {
            'empty name and callback_url' => {
              given: {},
              want: ['name must be filled', 'callback_url must be filled' ],
            },
            'invalid callback url' => {
              given: { callback_url: 'invalid url'},
              want: ['callback_url is invalid' ],
            },
          }.each do |title, t|
              it title do
                visit '/clients/new'
                fill_in :name, with: t[:given][:name]
                fill_in :callback_url, with: t[:given][:callback_url]
                click_on 'Add'
                t[:want].each do |msg|
                  assert page.has_content?(msg)
                end
              end
            end
        end

        it 'creates new client' do
          visit '/clients/new'
          fill_in :name, with: 'New client'
          fill_in :callback_url, with: 'https://example.com'
          click_on 'Add'
          assert page.has_content?('Client successfully created')
        end
      end
    end

  end
end
