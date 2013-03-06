require 'sinatra'
require 'sinatra/contrib'
require 'thin'
require 'json'
require 'dm-core'
require 'dm-timestamps'
require 'dm-validations'
require 'dm-migrations'
require 'rest_client'
$LOAD_PATH << '.'
require 'seq-email'
require 'group-confirm'

DataMapper.setup(:default, ENV['DATABASE_URL'] || "sqlite3://#{Dir.pwd}/development.db")

class User
  include DataMapper::Resource

  belongs_to :group, :required => false

  property :id, Serial
  property :email, String, :required => true
  property :group_work, Boolean, :default => true
  property :learning_style, String
  property :expertise, String
  property :timezone, String
  property :image, String
  property :unsubscribed, Boolean, :default => false
  property :round, Integer, :default => 1
  property :group_confirmation, Boolean, :default => false

  property :unsubscribed_at, DateTime
  property :created_at, DateTime
  property :updated_at, DateTime

  validates_uniqueness_of :email
  validates_format_of :email, :as => :email_address
  
  after :create do
    send_welcome_email
    add_user_to_all_list
  end
  
  def send_welcome_email
    body_html = File.read('emails/signup-confirmation.html')
    body_text = File.read('emails/signup-confirmation.txt')
    subject = "Thanks for signing up"
    RestClient.post "https://api:#{ENV['MAILGUN_API_KEY']}"\
    "@api.mailgun.net/v2/mechanicalmooc.org/messages",
    :from => "The Machine <the-machine@mechanicalmooc.org>",
    :to => email,
    :subject => subject,
    :text => body_text,
    :html => body_html
  end

  def add_user_to_all_list
    RestClient.post("https://api:#{ENV['MAILGUN_API_KEY']}" \
                    "@api.mailgun.net/v2/lists/python-all@mechanicalmooc.org/members",
                    :address => email,
                    :upsert => 'yes')
  end

end

class Group
  include DataMapper::Resource

  has n, :users

  property :id, Serial
  property :timezone, String

  property :created_at, DateTime
  property :updated_at, DateTime
  
  after :create, :start_list
  after :save, :upsert_list_members
  after :update, :upsert_list_members
  after :destroy, :delete_list

  def start_list
    RestClient.post("https://api:#{ENV['MAILGUN_API_KEY']}" \
                      "@api.mailgun.net/v2/lists",
                      :address => list_address,
                      :access_level => 'members',
                      :description => "Unconfirmed - #{timezone}")
    RestClient.post("https://api:#{ENV['MAILGUN_API_KEY']}" \
                    "@api.mailgun.net/v2/lists/#{list_address}/members",
                    :address => "the-machine@mechanicalmooc.org",
                    :upsert => 'yes')
  end
  
  def upsert_list_members
    # puts "Adding members"
    users.each do |u|
      RestClient.post("https://api:#{ENV['MAILGUN_API_KEY']}" \
                      "@api.mailgun.net/v2/lists/#{list_address}/members",
                      :address => u.email,
                      :upsert => 'yes')
    end
  end

  def delete_list
    RestClient.delete("https://api:#{ENV['MAILGUN_API_KEY']}" \
                      "@api.mailgun.net/v2/lists/#{list_address}")
  end
  
  def list_address
    "python-#{id}@mechanicalmooc.org"
  end
end

class MoocLog
  include DataMapper::Resource

  property :id, Serial
  property :created_at, DateTime
  
  property :event, String
  property :recipient, String
  property :domain, String
  property :message_headers, String
  property :message_id, String
  property :timestamp, String
  property :extra, String

end


DataMapper.finalize
DataMapper.auto_upgrade!

# Begin Web server portion
################################################################################

get '/' do
  File.read(File.join('public', 'index.html'))
end

post '/signup' do
  User.create(
    :email => params[:email],
    :group_work => params[:groupRadios],
    :learning_style => params[:styleRadios],
    :expertise => params[:expertiseRadios],
    :timezone => params[:timezone],
    :round => 4
  )
  "Thanks for signing up, we'll email you soon."
end

post '/mooc-mailgun-log' do
  group_from_header_regex = /python-[0-9]{1,4}@mechanicalmooc.org/
  s = MoocLog.create(
                 :event => params.delete("event").to_s,
                 :recipient => params.delete("recipient").to_s,
                 :domain => params.delete("domain").to_s,
                 :message_headers => params.delete("message-headers").to_s[group_from_header_regex],
                 :message_id => params.delete("Message-Id").to_s,
                 :timestamp => params.delete("timestamp").to_s)
                 # :extra => params.to_s[0..50])
  "400 OK"
end

get '/confirm' do
  GroupConfirm.confirm(params[:email], params[:auth_token])
  File.read(File.join('public', 'confirmed.html'))
end


# admin uris
###########################################################################################

# Http auth stuff 
# Set the admin user and pass in heroku config

helpers do
  def protected!
    unless authorized?
      response['WWW-Authenticate'] = %(Basic realm="Restricted Area")
      throw(:halt, [401, "Not authorized\n"])
    end
  end

  def authorized?
    @auth ||=  Rack::Auth::Basic::Request.new(request.env)
    @auth.provided? && @auth.basic? && @auth.credentials && @auth.credentials == [ENV['ADMIN_USER'], ENV['ADMIN_PASS']]
  end
end


get '/admin' do
  protected!
  File.read(File.join('public', 'admin.html'))
end

post '/admin/send-email' do
  protected!
  html_body = '<html><body style="margin: 0; font-family: sense, helvetica, sans-serif;">'
  html_body += params[:body_text]
  if params[:include_footer]
    html_body += File.read(File.join('email-footers', "#{params[:sequence]}.html"))
  end
  html_body += '</body></html>'

  stream do |out|
    se = SequenceEmail.new(out)
    se.sequence = params[:sequence]
    se.subject = params[:subject]
    se.body = html_body
    se.tags += params[:tags].split(",")
    se.send!
  end  
end

post '/admin/send-test-email' do
  protected!
  html_body = '<html><body style="margin: 0; font-family: sense, helvetica, sans-serif;">'
  html_body += 'THIS IS A TEST EMAIL!!! <hr />'
  html_body += params[:body_text]
  if params[:include_footer]
    html_body += File.read(File.join('email-footers', "#{params[:sequence]}.html"))
  end
  html_body += '</body></html>'
  
  se = SequenceEmail.new
  se.subject = params[:subject]
  se.body = html_body
  se.tags << "test"
  se.send_email_to(params[:test_email])
  
end

get '/admin/user-count' do
  content_type :json
  round = params[:round].match(/\d+/)[0]
  User.all(:round => round).count.to_json
end
