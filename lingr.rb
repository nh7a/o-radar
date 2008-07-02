#
# Lingr API Classes
#
# Copyright (c) 2007 Naoki Hiroshima
# You can redistribute it and/or modify it under the same terms as api_client.rb.
#
# Author:: Naoki Hiroshima <n at h7a dot org>
# Author:: Satoshi NAKAGAWA
#
# This is yet another Ruby client for the Lingr[http://www.lingr.com] API.
# The essential part of this module is actually copied from official Ruby
# client, that is, api_client.rb.  The differences are the way to call
# Lingr method and its result.
# For working sample, please see sample.lingr.rb.

$KCODE = 'u'
require 'jcode'
require 'net/http'
require 'cgi'
require 'thread'

module Lingr

  class Api
    # 0 = quiet, 1 = some debug info, 2 = more debug info
    attr_accessor :verbosity
    attr_accessor :timeout
    attr_accessor :params

    def initialize(api_key, verbosity=0, hostname='www.lingr.com')
      @host = hostname
      @verbosity = verbosity
      @timeout = 120
      @params = {:api_key => api_key}
    end

    private

    def method_missing(cmd, *args)
      return params[cmd.to_sym] unless args[0]

      path = "#{cmd}/#{args[0].to_s}"
      params = (args[1].is_a? Hash) ? args[1] : {}

      res = do_api path, @params.merge(params)
      p res, 1 if res.fail?

      if path == 'session/create' && res.ok?
        @params[:session] = res[:session]
      end

      res
    end

    def do_api(path, parameters)
      p "#{path} #{parameters.inspect}", 3

      json = get url_for(path), parameters.merge({ :format => 'json' })
      response = json_to_hash json
      res = Response.new response

      p "===> #{res}\n", 3
      p "===> #{res.response.inspect}\n", 4
      res

    rescue Exception
      p $!.backtrace, 0
      p $!.to_s, 0
      Response.new
    end

    def url_for(method)
      "http://#{@host}/#{@@PATH_BASE}#{method}"
    end

    def get(url, params)
      uri = URI.parse(url)
      path = uri.path
      q = params.inject("?") {|s, p| s << "#{p[0].to_s}=#{CGI.escape(p[1].to_s)}&"}.chop
      path << q if q.length > 0

      begin
        Net::HTTP.start(uri.host, uri.port) { |http| 
          http.read_timeout = @timeout
          req = Net::HTTP::Get.new(path)
          req.basic_auth(uri.user, uri.password) if uri.user
          parse_result http.request(req)
        }
      rescue Exception
        p "exception on HTTP GET: #{$!}", 2
        nil
      end
    end

    def parse_result(result)
      return nil if !result || result.code != '200' || (!result['Content-Type'] || result['Content-Type'].index('text/javascript') != 0)
      result.body
    end

    def p(msg, level=0)
      puts msg if level <= @verbosity
    end

    def json_to_hash(json)
      return nil if !json
      return nil unless /^\s*\{\s*["']/m =~ json
      begin
        null = nil
        return eval(json.gsub(/(["'])\s*:\s*(['"0-9tfn\[{])/){"#{$1}=>#{$2}"}.gsub(/\#\{/, '\#{'))
      rescue SyntaxError
        p $!
        return nil
      else
        return nil
      end
    end

    @@PATH_BASE = 'api/'
  end

  class Response
    attr_reader :code, :message, :response

    def initialize(res=nil)
      if !res.is_a?(Hash)
        @code = -1
        @message = 'nil response'
        @response = {}
      else
        @response = res
        if res['status'] == 'ok'
          @code = 0
          @message = 'ok'
        elsif res['status'] == nil
          @code = -2
          @message = "corrupt response (#{res.inspect})"
        else
          if @response['error']
            @code = @response['error']['code'].to_i
            @message = @response['error']['message']
          else
            @code = -3
            @message = "unknown reason (#{res.inspect})"
          end
        end
      end
    end

    def [](item); @response[item.to_s]; end
    def ok?; @code == 0; end
    def fail?; @code != 0; end
    def to_s; ok? ? @message : "#{@code} #{@message}"; end
  end
end
