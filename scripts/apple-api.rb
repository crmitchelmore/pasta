# frozen_string_literal: true
# Shared Apple API transport and renewable JWT signing.
require "base64"
require "json"
require "net/http"
require "openssl"
require "optparse"
require "uri"

module AppleAPI
  class ApiError < StandardError
    attr_reader :status, :body

    def initialize(message, status: nil, body: nil)
      super(message)
      @status = status
      @body = body
    end
  end

  # Raised only for HTTP 409: the resource we tried to create already exists
  # (typically because a concurrent worker or manual portal edit created it).
  class ConflictError < ApiError; end

  # Raised when a fetched resource does not match what was requested, or a
  # duplicate-reported resource never becomes visible. Never retried.
  class ValidationError < StandardError; end

  def self.base64url(value)
    Base64.urlsafe_encode64(value, padding: false)
  end

  def self.jwt_token(key_id:, issuer_id:, private_key:, now: Time.now)
    header = base64url(JSON.generate(alg: "ES256", kid: key_id, typ: "JWT"))
    issued_at = now.to_i
    payload = base64url(JSON.generate(iss: issuer_id, iat: issued_at, exp: issued_at + 1_200, aud: "appstoreconnect-v1"))
    unsigned_token = "#{header}.#{payload}"
    der_signature = private_key.dsa_sign_asn1(OpenSSL::Digest::SHA256.digest(unsigned_token))
    sequence = OpenSSL::ASN1.decode(der_signature)
    raw_signature = sequence.value.map { |integer| integer.value.to_s(2).rjust(32, "\0") }.join
    "#{unsigned_token}.#{base64url(raw_signature)}"
  end

  # Thin transport: performs one HTTPS request and returns [status, raw_body].
  # Tests substitute any object responding to call(method:, path:, body:).
  class HttpTransport
    def initialize(api_base:, token:)
      @api_base = api_base
      @token = token
    end

    def call(method:, path:, body: nil)
      uri = URI.join(@api_base, path)
      raise "Unexpected Apple API host" unless uri.scheme == "https" && uri.host == "api.appstoreconnect.apple.com"
      request = method.new(uri)
      request["Authorization"] = "Bearer #{@token}"
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(body) if body
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(request) }
      [Integer(response.code), response.body]
    end
  end

  # Classifies responses: 2xx parses and returns JSON, 409 raises
  # ConflictError, anything else raises ApiError (including 401/403 auth and
  # 400 validation failures, which callers must not treat as conflicts).
  class Client
    def initialize(transport:)
      @transport = transport
    end

    def request(method:, path:, body: nil)
      status, raw = @transport.call(method: method, path: path, body: body)
      if (200..299).cover?(status)
        return nil if raw.nil? || raw.empty?

        return JSON.parse(raw)
      end

      message = "App Store Connect API #{method::METHOD} #{path} failed (#{status}): #{raw}"
      raise ConflictError.new(message, status: status, body: raw) if status == 409

      raise ApiError.new(message, status: status, body: raw)
    end

    def get(path)
      request(method: Net::HTTP::Get, path: path)
    end

    def post(path, body)
      request(method: Net::HTTP::Post, path: path, body: body)
    end

    def list(path)
      get(path).fetch("data")
    end
  end

end
