require_relative 'github'
require_relative 'workers'
require 'chronic'
require 'date'
require 'sinatra/base'
require 'fileutils'
require 'json'
require 'octokit'
require 'rest-client'
require 'sinatra/config_file'
require 'whedon'
require 'yaml'
require 'pry'

include GitHub

class WhedonApi < Sinatra::Base
  register Sinatra::ConfigFile

  set :views, Proc.new { File.join(root, "responses") }

  config_file "config/settings-#{ENV['RACK_ENV']}.yml"
  set :configs, {}
  set :initialized, false

  before do
    set_configs unless journal_configs_initialized?

    if %w[heartbeat].include? request.path_info.split('/')[1]
      pass
    else
      sleep(2) unless testing? # This seems to help with auto-updating GitHub issue threads
      params = JSON.parse(request.env["rack.input"].read)

      # Only work with issues. Halt if there isn't an issue in the JSON
      halt 422 if params['issue'].nil?

      @action = params['action']
      @payload = params

      if @action == 'opened' || @action == 'closed'
        @message = params['issue']['body']
      elsif @action == 'created'
        @message = params['comment']['body']
      end

      @sender = params['sender']['login']
      @issue_id = params['issue']['number']
      @nwo = params['repository']['full_name']
      @config = settings.configs[@nwo]

      halt 422 unless @config # We probably want to restrict this
    end
  end

  def journal_configs_initialized?
    settings.initialized
  end

  def testing?
    ENV['RACK_ENV'] == "test"
  end

  def serialized_config
    @config.to_h
  end

  def set_configs
    # 'settings.journals' comes from sinatra/config_file
    settings.journals.each do |journal|
      journal.each do |nwo, params|
        team_id = params["editor_team_id"]
        params["editors"] = github_client.team_members(team_id).collect { |e| e.login }.sort
        settings.configs[nwo] = OpenStruct.new params
      end
    end

    settings.initialized = true
  end

  def say_hello
    if issue.title.match(/^\[REVIEW\]:/)
      respond erb :reviewer_welcome, :locals => { :reviewer => reviewers, :nwo => @nwo, :reviewers => @config.reviewers }
    # Newly created [PRE REVIEW] issue. Time to say hello
    elsif assignees.any?
      repo_detect
      respond erb :welcome, :locals => { :editor => assignees.first, :reviewers => @config.reviewers }
    else
      repo_detect
      respond erb :welcome, :locals => { :editor => nil, :reviewers => @config.reviewers }
    end
    process_pdf
  end

  # When an issue is closed we want to encourage authors to add the JOSS status
  # badge to their README but also potentially donate to JOSS (and sign up as a
  # future reviewer)
  def say_goodbye
    if review_issue?
      # If the REVIEW has been marked as 'accepted'
      if issue.labels.collect {|l| l.name }.include?('accepted')
        respond erb :goodbye, :locals => {:site_host => @config.site_host,
                                          :site_name => @config.site_name,
                                          :reviewers => @config.reviewers_signup,
                                          :doi_prefix => @config.doi_prefix,
                                          :doi_journal => @config.journal_alias,
                                          :issue_id => @issue_id,
                                          :donate_url => @config.donate_url}
      end
    end
  end

  def review_issue?
    issue.title.match(/^\[REVIEW\]:/)
  end

  def assignees
    @assignees ||= github_client.issue(@nwo, @issue_id).assignees.collect { |a| a.login }
  end

  # One giant case statement to decide how to handle an incoming message...
  def robawt_respond
    case @message
    when /\A@whedon commands/i
      if @config.editors.include?(@sender)
        respond erb :commands
      else
        respond erb :commands_public
      end
    when /\A@whedon assign (.*) as reviewer/i
      check_editor
      assign_reviewer($1)
      respond "OK, the reviewer is #{$1}"
    when /\A@whedon add (.*) as reviewer/i
      check_editor
      add_reviewer($1)
      respond "OK, #{$1} is now a reviewer"
    when /\A@whedon remove (.*) as reviewer/i
      check_editor
      remove_reviewer($1)
      respond "OK, #{$1} is no longer a reviewer"
    when /\A@whedon assign (.*) as editor/i
      check_editor
      assign_editor($1)
      respond "OK, the editor is #{$1}"
    when /\A@whedon set (.*) as archive/
      check_editor
      assign_archive($1)
    when /\A@whedon set (.*) as version/
      check_editor
      assign_version($1)
    when /\A@whedon start review/i
      check_editor
      if editor && reviewers.any?
        review_issue_id = start_review
        respond erb :start_review, :locals => { :review_issue_id => review_issue_id, :nwo => @nwo }
      else
        respond erb :missing_editor_reviewer
        halt
      end
    when /\A@whedon list editors/i
      respond erb :editors, :locals => { :editors => @config.editors }
    when /\A@whedon list reviewers/i
      respond all_reviewers
    when /\A@whedon generate pdf from branch (.*)/
      process_pdf($1)
    when /\A@whedon generate pdf/i
      process_pdf
    when /\A@whedon accept deposit=true/i
      check_eic
      deposit(dry_run=false)
    when /\A@whedon accept/i
      check_editor
      deposit(dry_run=true)
    when /\A@whedon check references from branch (.*)/
      check_references($1)
    when /\A@whedon check references/i
      check_references
    # Detect strings like '@whedon remind @arfon in 2 weeks'
    when /\A@whedon remind (.*) in (.*) (.*)/i
      check_editor
      schedule_reminder($1, $2, $3)
    end
  end

  def schedule_reminder(human, size, unit)
    # Check that the person we're expecting to remind is actually
    # mentioned in the issue body (i.e. is a reviewer or author)
    issue = github_client.issue(@nwo, @issue_id)
    unless issue.body.match(/#{human}/m)
      respond "#{human} doesn't seem to be a reviewer or author for this submission."
      halt
    end

    unless issue.title.match(/^\[REVIEW\]:/)
      respond "Sorry, I can't set reminders on PRE-REVIEW issues."
      halt
    end

    schedule_at = target_time(size, unit)

    if schedule_at
      # Schedule reminder
      ReviewReminderWorker.perform_at(schedule_at, human, @nwo, @issue_id, serialized_config)
      respond "Reminder set for #{human} in #{size} #{unit}"
    else
      respond "I don't recognize this description of time '#{size}' '#{unit}'."
    end
  end

  # Return Date object + some number of days specified
  def target_time(size, unit)
    Chronic.parse("in #{size} #{unit}")
  end

  # How Whedon talks
  def respond(comment, nwo=nil, issue_id=nil)
    nwo ||= @nwo
    issue_id ||= @issue_id
    github_client.add_comment(nwo, issue_id, comment)
  end

  # Check if the review issue has an archive DOI set already
  def archive_doi?
    archive = issue.body[/(?<=\*\*Archive:\*\*.<a\shref=)"(.*?)"/]
    if archive
      return true
    else
      return false
    end
  end

  def check_references(custom_branch=nil)
    if custom_branch
      respond "```\nAttempting to check references... from custom branch #{custom_branch}\n```"
    else
      respond "```\nAttempting to check references...\n```"
    end

    DOIWorker.perform_async(@nwo, @issue_id, serialized_config, custom_branch)
  end

  def deposit(dry_run)
    if review_issue?
      if !archive_doi?
        respond "No archive DOI set. Exiting..."
        return
      end

      if dry_run == true
        respond "```\nAttempting dry run of processing paper acceptance...\n```"
        DOIWorker.perform_async(@nwo, @issue_id, serialized_config)
        DepositWorker.perform_async(@nwo, @issue_id, serialized_config, dry_run=true)
      else
        label_issue(@nwo, @issue_id, ['accepted'])

        respond "```\nDoing it live! Attempting automated processing of paper acceptance...\n```"
        DepositWorker.perform_async(@nwo, @issue_id, serialized_config, dry_run=false)
      end
    else
      respond "I can't accept a paper that hasn't been reviewed!"
    end
  end

  # Download and compile the PDF
  def process_pdf(custom_branch=nil)
    # TODO refactor this so we're not passing so many arguments to the method
    if custom_branch
      respond "```\nAttempting PDF compilation from custom branch #{custom_branch}. Reticulating splines etc...\n```"
    else
      respond "```\nAttempting PDF compilation. Reticulating splines etc...\n```"
    end

    PDFWorker.perform_async(@nwo, @issue_id, serialized_config, custom_branch)
  end

  # Detect the languages and license of the review repository
  def repo_detect
    RepoWorker.perform_async(@nwo, @issue_id, serialized_config)
  end

  # Update the archive on the review issue
  def assign_archive(doi_string)
    doi = doi_string[/\b(10[.][0-9]{4,}(?:[.][0-9]+)*\/(?:(?!["&\'<>])\S)+)\b/]
    if doi
      doi_with_url = "<a href=\"https://doi.org/#{doi}\" target=\"_blank\">#{doi}</a>"
      new_body = issue.body.gsub(/\*\*Archive:\*\*\s*(.*|Pending)/i, "**Archive:** #{doi_with_url}")
      github_client.update_issue(@nwo, @issue_id, issue.title, new_body)
      respond "OK. #{doi_with_url} is the archive."
    else
      respond "#{doi_string} doesn't look like an archive DOI."
    end
  end

  # Update the version on the review issue
  def assign_version(version_string)
    if version_string
      new_body = issue.body.gsub(/\*\*Version:\*\*\s*(.*)/i, "**Version:** #{version_string}")
      github_client.update_issue(@nwo, @issue_id, issue.title, new_body)
      respond "OK. #{version_string} is the version."
    else
      respond "#{version_string} doesn't look like a valid version string."
    end
  end

  # Returns a string response with URL to Gist of reviewers
  def all_reviewers
    "Here's the current list of reviewers: #{@config.reviewers}"
  end

  # Change the editor on an issue. This is a two-step process:
  # 1. Change the review issue assignee
  # 2. Update the editor listed at the top of the issue

  # TODO: Refactor this mess
  def assign_editor(new_editor)
    new_editor = new_editor.gsub(/^\@/, "").strip
    new_body = issue.body.gsub(/\*\*Editor:\*\*\s*(@\S*|Pending)/i, "**Editor:** @#{new_editor}")
    # This line updates the GitHub issue with the new editor
    github_client.update_issue(@nwo, @issue_id, issue.title, new_body, :assignees => [])

    unless @config.site_host == "https://jose.theoj.org"
      # Next update JOSS/JCON application to notify the editor has been changed
      # Currently we're only doing this for JOSS/JCON
      url = "#{@config.site_host}/papers/api_assign_editor?id=#{@issue_id}&editor=#{new_editor}&secret=#{@config.site_api_key}"
      response = RestClient.post(url, "")
    end

    reviewer_logins = reviewers.map { |reviewer_name| reviewer_name.sub(/^@/, "") }
    update_assignees([new_editor] | reviewer_logins)
  end

  # Change the reviewer listed at the top of the issue (clobber any that exist)
  def assign_reviewer(new_reviewer)
    set_reviewers([new_reviewer])
  end

  # Add a reviewer (don't clobber existing ones)
  def add_reviewer(reviewer)
    set_reviewers(reviewers + [reviewer])
  end

  # Remove a reviewer from the list
  def remove_reviewer(reviewer)
    set_reviewers(reviewers - [reviewer])
  end

  def set_reviewers(reviewer_list)
    reviewer_logins = reviewer_list.map { |reviewer_name| reviewer_name.sub(/^@/, "").downcase }.uniq
    label = reviewer_list.empty? ? "Pending" : reviewer_list.join(", ")
    new_body = issue.body.gsub(/\*\*Reviewers?:\*\*\s*(.+?)\r?\n/i, "**Reviewers:** #{label}\r\n")
    reviewer_logins.each do |reviewer_name|
      github_client.add_collaborator(@nwo, reviewer_name)
    end
    github_client.update_issue(@nwo, @issue_id, issue.title, new_body, :assignees => [])
    update_assignees([editor] | reviewer_logins)
  end

  def editor
    issue.body.match(/\*\*Editor:\*\*\s*.@(\S*)/)[1]
  end

  def reviewers
    issue.body.match(/Reviewers?:\*\*\s*(.+?)\r?\n/)[1].split(", ") - ["Pending"]
  end

  # Send an HTTP POST to the GitHub API here due to Octokit problems
  def update_assignees(logins)
    data = { "assignees" => logins }
    url = "https://api.github.com/repos/#{@nwo}/issues/#{@issue_id}/assignees?access_token=#{ENV['GH_TOKEN']}"
    RestClient.post(url, data.to_json)
  end

  # This method is called when an editor says: '@whedon start review'.
  # At this point, Whedon talks to the JOSS/JOSE application which creates
  # the actual review issue and responds with the serialized paper which
  # includes the 'review_issue_id' which is posted back into the PRE-REVIEW
  def start_review
    # Check we have an editor and a reviewer
    if review_issue? # Don't start a review if it has already started
      respond "Can't start a review when the review has already started"
      halt 422
    end

    if reviewers.empty?
      respond "Can't start a review without reviewers"
      halt 422
    end

    if !editor
      respond "Can't start a review without an editor"
      halt 422
    end

    reviewer_logins = reviewers.map { |reviewer_name| reviewer_name.sub(/^@/, "") }
    url = "#{@config.site_host}/papers/api_start_review?id=#{@issue_id}&editor=#{editor}&reviewers=#{reviewer_logins.join(',')}&secret=#{@config.site_api_key}"
    # TODO let's do some error handling here please
    response = RestClient.post(url, "")
    paper = JSON.parse(response)
    return paper['review_issue_id']
  end

  # Return an Octokit GitHub Issue
  def issue
    @issue ||= github_client.issue(@nwo, @issue_id)
  end

  # Check that the person sending the command is an editor
  def check_editor
    unless @config.editors.include?(@sender)
      respond "I'm sorry @#{@sender}, I'm afraid I can't do that. That's something only editors are allowed to do."
      halt 403
    end
  end

  # Check that the person sending the command is an editor-in-chief
  def check_eic
    unless @config.eics.include?(@sender)
      respond "I'm sorry @#{@sender}, I'm afraid I can't do that. That's something only editor-in-chiefs are allowed to do."
      halt 403
    end
  end

  # The actual Sinatra URL path methods
  get '/heartbeat' do
    "BOOM boom. BOOM boom. BOOM boom."
  end

  post '/dispatch' do
    if @action == "opened"
      say_hello
      halt
    end

    if @action == "closed"
      say_goodbye
      halt
    end

    robawt_respond if @message
  end
end
