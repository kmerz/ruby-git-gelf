#! /usr/bin/env ruby

require 'json'
require 'socket'
require 'date'

class Config

  LASTCOMMITS_FILE = "~/.lastcommits.json"

  attr_reader project_name

  def initialize
    @configFile = File.expand_path LASTCOMMITS_FILE
    @project_name = `basename \`git rev-parse --show-toplevel\``
  end

  def readCommits
    last_commits_json = File.read(@configFile)
    return JSON.parse(last_commits_json) || {}
  end

  def writeCommit(hash)
    last_commits = readCommits
    last_commits[@project_name] = hash
    File.write(@configFile, last_commits.to_json)
  end
end

class GitGraylog
  def initialize
    @config = Config.new
  end

  def getLog
    last_commits = readCommits
    project_name = `basename \`git rev-parse --show-toplevel\``
    if lastHash = last_commits[project_name]
      logs = `git graylog origin/master --no-merges --shortstat #{lastHash}..HEAD`.split("\n\n")
    else
      logs = `git graylog origin/master --no-merges --shortstat`.split("\n\n")
    end
  end
end

def send_result(log, index, stat_result={})
  project_name = `basename \`git rev-parse --show-toplevel\``
  result = log.match(/(.*) - (.*) - (.*) - (.*)/);
  date = DateTime.parse(result[1]).to_time

  if (index === 0)
    last_commit = result[3]
    writeCommit(last_commit)
  end

  weekday = date.strftime("%A")
  month = date.strftime("%B")
  hour = date.strftime("%H")
  minute = date.strftime("%M")
  seconds = date.strftime("%S")

  gelf_msg = {
    version: "1.1",
    host: "localhost",
    short_message: result[4],
    full_message: log,
    timestamp: date.to_f,
    level: 1,
    _author: result[2],
    _hash: result[3],
    _project: project_name,
    _hour: hour,
    _minute: minute,
    _seconds: seconds,
    _weekday: weekday,
    _month: month,
    _files_changed: stat_result[:files],
    _lines_add: stat_result[:add],
    _lines_removed: stat_result[:del]
  }

  s = TCPSocket.open("localhost", 12203)
  s.puts gelf_msg.to_json
  s.close
end

`git fetch`


logs.each_with_index do |log_stat, index|
  log_stat_arr = log_stat.lines
  if log_stat_arr.size > 3
    puts "OUT"
    puts log_stat_arr
  end
  if log_stat_arr.size > 2
    log = log_stat_arr.shift
    send_result(log, index)
  end
  log, stat = log_stat_arr
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
    puts log_stat
    exit
  end

  send_result(log, index, stat_result)
end

