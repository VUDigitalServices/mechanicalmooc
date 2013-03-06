# -*- coding: utf-8 -*-

require 'rest_client'
require 'multimap'
require 'active_model'
require 'html2markdown'
$LOAD_PATH << '.'
require 'mooc'


class SequenceEmail
  include ActiveModel::Validations
  
  attr_accessor :sequence, :tags, :subject, :body
  validates_presence_of :tags, :subject, :body, :sequence

  def initialize(output_stream = $stdout)
    @tags = []
    @output_stream = output_stream
  end

  def send!
    errors.clear
    return errors unless valid?
    if @sequence == "sequence_1"
      individual_users = User.all :group_work => false, :round => 1
      send_email_to_users( individual_users.collect{|u| u.email} , "bqtde")
      send_email_to_groups( 2..170 )
    elsif @sequence == "sequence_2"
      sequence2_users = User.all :group_work => false, :round => 2
      send_email_to_users( sequence2_users.collect{|u| u.email} , "br67o")
      send_email_to_groups( 171..187 )
    elsif @sequence == "sequence_3_all"
      sequence3_users = User.all :round => 3, :group_work => false, :group_confirmation => false
      send_email_to_users( sequence3_users.collect{|u| u.email} , "brmcg")      
      send_email_to_groups( 188..209 )
    elsif @sequence == "sequence_3_groups"
      send_email_to_groups( 188..209 )
    elsif @sequence == "sequence_4"
      sequence4_users = User.all :round => 4
      send_email_to_users( sequence4_users.collect{|u| u.email} , "bsesr")
    else
      @output_stream.puts "Not a valid sequence"
      return false
    end
  end

  def send_email_to(email_address)
    data = Multimap.new
    data[:from] = "The Machine <the-machine@mechanicalmooc.org>"
    data[:subject] = @subject
    data["o:tag"] = @tags && @tags.map{|t| t.to_s }.join(" ")
    data[:to] = email_address
    data[:html] = @body
    page = HTMLPage.new :contents => @body
    data[:text] = page.markdown
    RestClient.post("https://api:#{ENV['MAILGUN_API_KEY']}"\
                    "@api.mailgun.net/v2/mechanicalmooc.org/messages", data)
  end

  private

  def send_email_to_users(email_addresses, campaign_id)
    email_addresses.each do |email_address|
      data = Multimap.new
      data[:from] = "The Machine <the-machine@mechanicalmooc.org>"
      data[:subject] = @subject
      data["o:tag"] = @tags && @tags.map{|t| t.to_s }.join(" ")
      data[:to] = email_address
      data[:html] = @body
      page = HTMLPage.new :contents => @body
      data[:text] = page.markdown
      # data["o:testmode"] = "true"
      data["o:tag"] = "production"
      data["o:campaign"] = campaign_id
      data["o:tracking"] = "yes"
      data["o:tracking-clicks"] = "yes"
      data["o:tracking-opens"] = "yes"
      @output_stream << "Sending email to " + data[:to].join(', ') + "...    "
      @output_stream << RestClient.post("https://api:#{ENV['MAILGUN_API_KEY']}"\
                                        "@api.mailgun.net/v2/mechanicalmooc.org/messages", data)
      @output_stream << "\n<br />"
    end
  end

  def send_email_to_groups(group_numbers)
    group_numbers.each do |group_number|
      data = Multimap.new
      data[:from] = "The Machine <the-machine@mechanicalmooc.org>"
      data[:subject] = @subject
      data[:to] = "python-#{group_number}@mechanicalmooc.org"
      data[:html] = @body
      page = HTMLPage.new :contents => @body
      data[:text] = page.markdown
      data["o:tag"] = "production"
      # data["o:testmode"] = "true"
      data["o:tag"] = @tags && @tags.map{|t| t.to_s }.join(" ")
      data["o:tracking"] = "yes"
      data["o:tracking-clicks"] = "yes"
      data["o:tracking-opens"] = "yes"

      @output_stream << "Sending email to " + data[:to].join(', ') + "...    "
      @output_stream << RestClient.post("https://api:#{ENV['MAILGUN_API_KEY']}"\
                                        "@api.mailgun.net/v2/mechanicalmooc.org/messages", data)
      @output_stream << "\n<br />"
    end
  end
  
end



