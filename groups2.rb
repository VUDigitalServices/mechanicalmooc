require 'rest_client'
require 'json'
$LOAD_PATH << '.'
require 'mooc'
require 'pp'
require 'logger'
require 'ruby-debug'


ENV['MAILGUN_API_KEY'] = "key-4kkoysznhb93d1hn8r37s661fgrud-66"
RestClient.log = 'restclient.log'


module UserGroupMethods
  def grouped_users
    @groups.flatten
  end

  def ungrouped_users
    @users - grouped_users
  end

  def shuffle_users!
    # shuffle the deck of users 7 times. Poker pays off
    7.times{ @users.shuffle! }
  end
end

class MatchGroup < Array
  attr_accessor :properties

  def initialize(props = {})
    @properties = props
    super()
  end
  
  def most_frequent(name)
    r = group_by{|g| g.send(name) }.max_by{|i, o| o.size}
    r ? r.flatten.last.send(name) : ''
  end

  def add_user(user)
    push(user)
  end

  def method_missing(method, *args)
    most_frequent(method)
  end

  def inspect
    @properties.inspect + super
  end
  
end



class MatchingStrategy
  include UserGroupMethods
  
  def name
    self.class.to_s
  end

  def setup(logger, users, groups)
    @log = logger
    @users = users
    @groups = groups
    
  end

  def run_all
    run_before_match
    run_match
    run_after_match
  end

  def run_match
    return @log.warn "'match' not implemented for #{name}" unless respond_to? :match
    @users.each do |user|
      @groups.shuffle!
      @log.debug "Matching #{user.inspect} using #{name}"
      group = match(user, @groups)
      if group
        @log.debug "Matched to group: #{group.inspect}"
        group.add_user(user)
        @groups << group unless @groups.include? group
        @log.debug "Number of available groups: #{@groups.size}"
      else
        @log.debug "Could not find a group for user: #{user.inspect}"
      end      
    end    
  end

  def run_before_match
    return @log.warn "'before_match' not implemented for #{name}" unless respond_to? :before_match
    before_match(@users, @groups)
  end

  def run_after_match
    return @log.warn "'after_match' not implemented for #{name}" unless respond_to? :after_match
    after_match(@users, @groups)
  end

  private

  attr_accessor :users, :groups
  
end





class SpecificStrategy < MatchingStrategy
  attr_accessor :rules, :create_group_on_not_found, :respect_target_sizes

  def initialize
    @rules = []
    @create_group_on_not_found = false
    @respect_target_sizes = true
  end

  def add_rule( &block )
    @rules << block
  end

  def match(user, groups)
    groups.each do |group|
      if @respect_target_sizes
        if group.size < group.properties[:target_size].to_i
          return group if @rules.any?{|r| r.call(user, group) }      
        end
      end
    end
    @create_group_on_not_found ? MatchGroup.new : false
  end

end





class MakeGroupStrategy < MatchingStrategy
  attr_accessor :groups_to_make, :min_group_size, :user_criteria

  def initialize
    @groups_to_make = {}
    @user_criteria = []
  end

  def before_match(users, groups)
    @groups_to_make.each do |size, number_of_that_size|
      number_of_that_size.to_i.times do
        groups << MatchGroup.new(:target_size => size)
      end
    end
  end
end

class DistributeInitialStrategy < MatchingStrategy
  attr_accessor :criteria

  def before_match(users, groups)
    return unless @criteria
    criteria_freqs = users.group_by{|u| u.send(@criteria)}.map do |criteria, users|
      {users.size => users.first}
    end
    cf = criteria_freqs.sort_by{|h| h.keys.first}
    groups.each do |group|
      if group.size == 0
        group.add_user cf.pop.values.first
      end
    end
  end
end

class FoldSmallGroupStrategy < MatchingStrategy
  attr_accessor :hard_minimum, :relative_minimum

  def before_match(users, groups)
    groups.map do |group|
      if (@hard_minimum && group.size < @hard_minumum) ||
          (@relative_minimum && group.size < group.properties[:target_size].to_i - @relative_minimum )
        group.clear
      else
        group
      end
    end
    
  end
end

class MakeSpecificGroupStrategy < MatchingStrategy
  attr_accessor :groups_to_make

  def initialize
    @groups_to_make = []
  end

  def create_group(props)
    @groups_to_make << MatchGroup.new(props)
  end

  def before_match(users, groups)
    @groups_to_make.each do |g|
      groups << g
      @log.debug "Created group: #{g.inspect}"
    end
  end
  
end


class Classifier
  include UserGroupMethods
  attr_accessor :logger, :users, :groups
  attr_reader :matching_strategies, :groups
  
  def initialize(*matching_strategies)
    @matching_strategies = matching_strategies
    @users = []
    @groups = []
    init_logger
    @log.info "Setup classifier using: #{@matching_strategies.inspect}"
  end

  def init_logger
    @logger = Logger.new(STDOUT)
    @logger.level = Logger::DEBUG
    @log = @logger
  end

  def classify!
    @log.info "Started classifying"
    @matching_strategies.each do |ms|
      shuffle_users!      
      run(ms)
    end
    @log.debug "Results: "
    @log.debug @groups.inspect
    @log.warn "There are #{ungrouped_users.size} users that were not grouped"
    @log.warn "They are: \n #{ungrouped_users.inspect}"
  end

  def run(matching_strategy)
    return @log.error "#{ms} is not a valid MatchingStrategy" unless matching_strategy.is_a? MatchingStrategy
    @log.info "Running Matching Strategy: #{matching_strategy.name}"
    matching_strategy.setup(@logger, ungrouped_users, @groups)
    matching_strategy.run_all
    # run_before_match(matching_strategy)
    # run_match(matching_strategy)
    # run_after_match(matching_strategy)
  end

  def results_to_db!
    @groups.each do |group|
      dm_group = Group.new
      dm_group.users = group
      dm_group.timezone = group.timezone
      dm_group.save
    end
  end

  def prompt_for_save_to_db!
    puts "Would you like to use these groups? (type 'yes' to save)"
    answer = gets.chomp
    if answer == 'yes'
      results_to_db!
    end
  end

  def results_to_file(file_name)
    open(file_name, 'w') do |file|
      file.puts "Total Groups: " + @groups.size.to_s
      @groups.uniq(&:size).each do |group|
        file.puts "\tGroups with " + group.size.to_s + " members: " + 
                   @groups.select{|g| g.size == group.size}.size.to_s
      end
      file.puts "Total Users to Group: " + @users.size.to_s
      file.puts "Total Grouped Users: " + grouped_users.size.to_s
      file.puts "Unique Timezone Groups: " + @groups.collect(&:timezone).uniq.count.to_s
      file.puts "Unique Timezone Users: " + @groups.collect(&:timezone).uniq.count.to_s
      @groups.each_with_index do |group, index|
        file.puts "\nGroup " + (index + 1).to_s
        file.puts "\tTarget Size: " + group.properties[:target_size]
        file.puts "\tCurrent Size: " + group.size.to_s
        file.puts "\tTimezone: " + group.timezone
        file.puts "\tUsers:"
        group.each do |user|
          file.puts "\t\tUser " + user.id.to_s + ": \t\t" + 
                    [user.email, user.timezone, user.expertise].join(", ")
        end
      end
    end
  end
 
end






mgs = MakeGroupStrategy.new
mgs.groups_to_make = {'20' => 6, '40' => 5}

dis = DistributeInitialStrategy.new
dis.criteria = :timezone

sms = SpecificStrategy.new
sms.add_rule {|u, g| u.timezone == g.timezone }

sms2 = SpecificStrategy.new
sms2.add_rule {|u, g| u.timezone.split('/').first == g.timezone.split('/').first}
sms2.add_rule {|u, g| u.timezone.split('/').first == 'Pacific' && g.timezone.split('/').first == 'Asia'}
sms2.add_rule {|u, g| u.timezone.split('/').first == 'Africa' && g.timezone.split('/').first == 'Europe'}
sms2.add_rule {|u, g| u.timezone.split('/').first == 'Etc' && g.timezone.split('/').first == 'Asia'}

fsgs = FoldSmallGroupStrategy.new
fsgs.relative_minimum = 7

sms3 = SpecificStrategy.new
sms3.add_rule {|u, g| true }


c = Classifier.new(mgs, dis, sms, sms2, fsgs, dis, sms2, sms3)
c.logger.level = Logger::WARN
c.users = User.all( :round => 3, :group_work => true, :group_confirmation => false, :limit => 400 )
c.classify!
c.results_to_file('groups-unconfirmed.txt')
c.prompt_for_save_to_db!
