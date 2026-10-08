#!/usr/bin/env ruby
# frozen_string_literal: true
require_relative 'release-apple'
require 'open3'
client = AppleRelease::Client.new
output, status = Open3.capture2('git','for-each-ref','--format=%(refname:short)','refs/tags/alpha-build-*','refs/tags/stable-candidate-*')
abort 'Cannot read release ledger' unless status.success?
failures=[]
manifests=output.lines.map(&:strip).filter_map do |tag|
  data, result = Open3.capture2('git','for-each-ref','--format=%(contents)',"refs/tags/#{tag}")
  JSON.parse(data) if result.success?
end
# Only the newest Alpha can become the tester build. Submitting superseded
# Alphas would spend Apple's limited beta review slots on stale binaries.
newest_alpha=manifests.select { |m| m['train'] == 'alpha' }.max_by { |m| m['ordinal'].to_i }
# App Store submission follows the Sparkle release asynchronously, and only for
# the newest owner-approved Stable candidate; older approvals are superseded.
approved_stable=manifests.select { |m| m['train'] == 'stable' }.sort_by { |m| -m['ordinal'].to_i }.find do |m|
  AppleRelease::Delivery.new(client:client,manifest:m,surface:'ios').owner_approved?
rescue StandardError => error
  warn "#{m['tag']} approval: #{error.message}"
  false
end
manifests.each do |manifest|
  tag=manifest['tag']
  next if manifest['train'] == 'alpha' && !manifest.equal?(newest_alpha)
  # Expired Alpha builds remain in the ledger but cannot be made installable.
  # Rebuild explicitly if the most recent Alpha approaches TestFlight's 90 days.
  if manifest['train'] == 'alpha' && Time.parse(manifest['createdAt']) < Time.now - 90*86_400
    next
  end
  %w[ios].each do |surface|
    begin
      delivery=AppleRelease::Delivery.new(client:client,manifest:manifest,surface:surface)
      delivery.distribute(wait_seconds:0) if delivery.build
      delivery.submit_if_ready if manifest.equal?(approved_stable)
      delivery.observe_publication if manifest['train'] == 'stable'
    rescue StandardError => error
      warn "#{tag} #{surface}: #{error.message}"
      failures << "#{tag} #{surface}"
    end
  end
end
abort "Apple reconciliation needs attention: #{failures.join(', ')}" unless failures.empty?
