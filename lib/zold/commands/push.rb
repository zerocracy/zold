# frozen_string_literal: true

# Copyright (c) 2018 Yegor Bugayenko
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the 'Software'), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

require 'rainbow'
require 'slop'
require 'json'
require 'net/http'
require_relative 'args'
require_relative '../log'
require_relative '../id'
require_relative '../http'
require_relative '../json_page'
require_relative '../atomic_file'

# PUSH command.
# Author:: Yegor Bugayenko (yegor256@gmail.com)
# Copyright:: Copyright (c) 2018 Yegor Bugayenko
# License:: MIT
module Zold
  # Wallet pushing command
  class Push
    def initialize(wallets:, remotes:, log: Log::Quiet.new)
      @wallets = wallets
      @remotes = remotes
      @log = log
    end

    def run(args = [])
      opts = Slop.parse(args, help: true, suppress_errors: true) do |o|
        o.banner = <<~HELP.chomp
          Usage: zold push [ID...] [options]
          Available options:
        HELP
        o.bool '--ignore-score-weakness',
          'Don\'t complain when their score is too weak',
          default: false
        o.array '--ignore-node',
          'Ignore this node and don\'t push to it',
          default: []
        o.bool '--help', 'Print instructions'
      end
      mine = Args.new(opts, @log).take || return
      mine = @wallets.all if mine.empty?
      mine.map { |i| Id.new(i) }.each do |id|
        push(id, opts)
      end
    end

    private

    def push(id, opts)
      total = 0
      nodes = 0
      done = 0
      start = Time.now
      @remotes.iterate(@log) do |r|
        nodes += 1
        total += push_one(id, r, opts)
        done += 1
      end
      raise "There are no remote nodes, run 'zold remote reset'" if nodes.zero?
      raise "No nodes out of #{nodes} accepted the wallet #{id}" if done.zero?
      @log.info("Push finished to #{done} nodes out of #{nodes} in #{(Time.now - start).round}s, \
total score for #{id} is #{total}")
    end

    def push_one(id, r, opts)
      if opts['ignore-node'].include?(r.to_s)
        @log.debug("#{r} ignored because of --ignore-node")
        return 0
      end
      start = Time.now
      content = @wallets.find(id) do |wallet|
        raise "The wallet #{id} is absent" unless wallet.exists?
        AtomicFile.new(wallet.path).read
      end
      response = r.http("/wallet/#{id}#{opts['sync'] ? '?sync=true' : ''}").put(content)
      @wallets.find(id) do |wallet|
        if response.code == '304'
          @log.info("#{r}: same version #{content.length}b/#{wallet.txns.count}t \
of #{wallet.id} there, in #{(Time.now - start).round(2)}s")
          return 0
        end
        r.assert_code(200, response)
        json = JsonPage.new(response.body).to_hash
        score = Score.parse_json(json['score'])
        r.assert_valid_score(score)
        r.assert_score_ownership(score)
        r.assert_score_strength(score) unless opts['ignore-score-weakness']
        @log.info("#{r} accepted #{content.length}b/#{wallet.digest[0, 6]}/#{wallet.txns.count}t of #{wallet.id} \
in #{(Time.now - start).round(2)}s: #{Rainbow(score.value).green} (#{json['version']})")
        score.value
      end
    end
  end
end
