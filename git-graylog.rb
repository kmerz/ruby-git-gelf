#! /usr/bin/env ruby

require 'json'
require 'socket'
require 'date'

class Config
  LASTCOMMITS_FILE = "~/.lastcommits.json"

  def initialize(path = nil, flush = false)
    @configFile = File.expand_path LASTCOMMITS_FILE
    @config = readLastCommits
    @flush = flush
    unless path.nil?
      project_name = projectFromPath(path)
      @config[project_name] = {}
      @config[project_name]["path"] = File.expand_path(path)
    end
  end

  def projectFromPath(path)
    cwd = Dir.pwd
    Dir.chdir(path)
    name = `basename \`git rev-parse --show-toplevel\``.strip
    Dir.chdir(cwd)
    return name
  end

  def projects
    last_commits = @config
    return last_commits.keys
  end

  def pathForProject(project)
    @config[project]["path"]
  end

  def hashForProject(project)
    if @flush
      return nil
    end
    @config[project]["hash"]
  end

  def readLastCommits
    begin
      last_commits_json = File.read(@configFile).strip
    rescue Errno::ENOENT
      last_commits_json = "{}"
    end
    last_commits_json = "{}" if last_commits_json.empty?
    return JSON.parse(last_commits_json) || {}
  end

  def writeCommit(project_name, hash)
    @config[project_name]["hash"] = hash
    File.write(@configFile, @config.to_json)
  end
end

class GitGraylog
  def initialize(path = nil, flush = false)
    @config = Config.new(path, flush)
  end

  def gitFetch
    `git fetch`
  end

  def getLogs(project_name)
    path = @config.pathForProject(project_name)
    lastHash = @config.hashForProject(project_name)
    Dir.chdir(path)
    gitFetch
    return `#{gitCmd(lastHash)}`.split("\n\n")
  end

  def gitCmd(lastHash)
    cmd = ["git"]
    cmd << "log --pretty=format:'%cI - %an - %h - %s' --abbrev-commit"
    cmd << "--no-merges --shortstat origin/master "
    if lastHash
      cmd << "#{lastHash}..HEAD"
    end
    result =  cmd.join(' ')
    return result
  end

  def extractStats(log, stat)
    stat_result = {}
    if res = stat.match(/(\d+) files? changed, (\d+) insertions?.\+., (\d+) deletions?.\-./)
      stat_result = {
        files: res[1].to_i,
        add: res[2].to_i,
        del: res[3].to_i
      }
    elsif res = stat.match(/(\d+) files? changed, (\d+) insertions?.\+./)
      stat_result = {
        files: res[1].to_i,
        add: res[2].to_i,
      }
    elsif res = stat.match(/(\d+) files? changed, (\d+) deletions?.\-./)
      stat_result = {
        files: res[1].to_i,
        del: res[2].to_i,
      }
    else
      STDERR.puts "Unexpected format for files changed"
      STDERR.puts log_stat
      exit
    end
    return stat_result
  end

  def parseLog(project_name, log_stat)
    log_stat_arr = log_stat.lines

    if log_stat_arr.size > 3
      STDERR.puts "More lines than expected"
      STDERR.puts log_stat_arr
      return
    end

    if log_stat_arr.size > 2
      log = log_stat_arr.shift
      gelf_msg_short = log2gelf(project_name, log)
      send_result(gelf_msg_short)
    end

    log, stat = log_stat_arr
    stat_result = extractStats(log, stat)

    gelf_msg = log2gelf(project_name, log, stat_result)
    send_result(gelf_msg)
    return gelf_msg[:_hash]
  end

  def run
    projects = @config.projects
    projects.each do |project_name|
      logs = getLogs(project_name)

      logs.each_with_index do |log_stat, index|
        hash = parseLog(project_name, log_stat)
	if hash.nil?
	  next
	end
        if (index === 0)
          @config.writeCommit(project_name, hash)
        end
      end
    end
  end

  def gitLogShow(hash = "")
    `git show -s #{hash}`
  end

  def log2gelf(project_name, log, stat_result = {})
    result = log.match(/(.*) - (.*) - (.*) - (.*)/);
    date = DateTime.parse(result[1]).to_time

    hash = result[3]

    weekday = date.strftime("%A")
    dayOfMonth = date.strftime("%-d")
    dayOfTheWeek = date.strftime("%u")
    month = date.strftime("%B")
    hour = date.strftime("%H")
    minute = date.strftime("%M")
    seconds = date.strftime("%S")
    dayOfYear = date.strftime("%j")
    year = date.strftime("%Y")

    git_show_msg = gitLogShow(hash)

    gelf_msg = {
      version: "1.1",
      host: "localhost",
      short_message: result[4],
      full_message: log,
      timestamp: date.to_f,
      level: 1,
      _author: result[2],
      _hash: hash,
      _project: project_name,
      _hour: hour.to_i,
      _minute: minute.to_i,
      _seconds: seconds.to_i,
      _weekday: weekday,
      _month: month,
      _year: year.to_i,
      _dayOfYear: dayOfYear.to_i,
      _dayOfTheWeek: dayOfTheWeek.to_i,
      _dayOfMonth: dayOfMonth.to_i,
      _files_changed: stat_result[:files].to_i,
      _lines_add: stat_result[:add].to_i,
      _lines_removed: 0 - stat_result[:del].to_i,
      _git_show_message: git_show_msg
    }
  end

  def send_result(gelf_msg)
    s = TCPSocket.open("localhost", 12203)
    s.puts gelf_msg.to_json
    s.close
#    puts JSON.pretty_generate(gelf_msg)
  end
end

arg = ARGV.pop
if arg == '-f'
  flush = true
else
  path = arg
end

if !path.nil?
  unless File.directory?(path)
    STDERR.puts "error: #{path} does not exists or is not a directory"
    exit
  end

  unless File.directory?(path + "/.git")
    STDERR.puts "error: #{path} is not a git root"
    exit
  end
end

gitGraylog = GitGraylog.new(path, flush)
gitGraylog.run
