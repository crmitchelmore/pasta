#!/usr/bin/env ruby
# frozen_string_literal: true
# Uses Apple's published OpenAPI contract. Upload, beta review and public
# availability are different states; none is inferred from xcodebuild success.
require_relative 'apple-api'
require 'time'
require 'tmpdir'
require 'digest'
require 'open3'

module AppleRelease
  BETA_APP_DESCRIPTION = 'Pasta is a privacy-first clipboard history manager. Test clipboard history, search, sync, and experimental features in this public Alpha.'
  BETA_BUILD_LOCALE = 'en-US'
  BETA_FEEDBACK_EMAIL = 'support@pasta-app.com'
  BETA_MARKETING_URL = 'https://pasta-app.com'
  BETA_PRIVACY_POLICY_URL = 'https://github.com/crmitchelmore/pasta/blob/main/SECURITY.md'

  class Client < AppleAPI::Client
    def initialize
      @key_id = ENV.fetch('APP_STORE_CONNECT_KEY_ID', 'B3BM4F88FJ')
      @issuer = ENV.fetch('APP_STORE_CONNECT_ISSUER_ID')
      @key = OpenSSL::PKey.read(File.read(ENV.fetch('APP_STORE_CONNECT_KEY_PATH', File.expand_path("~/.appstoreconnect/private_keys/AuthKey_#{@key_id}.p8"))))
    end

    def request(method:, path:, body: nil)
      # Renew for every request, including long processing/review reconciliation.
      @transport = AppleAPI::HttpTransport.new(api_base: 'https://api.appstoreconnect.apple.com',
        token: AppleAPI.jwt_token(key_id: @key_id, issuer_id: @issuer, private_key: @key))
      super
    end

    def patch(path, body)
      request(method: Net::HTTP::Patch, path: path, body: body)
    end

    def list(path)
      results = []
      loop do
        page = get(path)
        results.concat(page.fetch('data'))
        path = page.dig('links', 'next')
        break unless path
      end
      results
    end
  end

  def self.relationship(type, id)
    {data: {type: type, id: id}}
  end

  class Delivery
    def initialize(client:, manifest:, surface:, repo: ENV.fetch('GITHUB_REPOSITORY', 'crmitchelmore/pasta'))
      @client, @manifest, @surface, @repo = client, manifest, surface, repo
      @item = manifest.fetch('surfaces').fetch(surface)
      raise 'Notes changed after approval' unless Digest::SHA256.hexdigest(@item.fetch('notes')) == @item.fetch('notesHash')
      raise 'Store notes changed after approval' unless Digest::SHA256.hexdigest(@item.fetch('storeNotes')) == @item.fetch('storeNotesHash')
      @train = manifest.fetch('train')
      @pipeline = JSON.parse(File.read('Config/ReleasePipeline.json'))
      @app = @pipeline.fetch('apple').fetch(@train).fetch(surface)
      @stable_app = @pipeline.fetch('apple').fetch('stable').fetch(surface)
      raise "Alpha App Store Connect record not configured for #{surface}" unless @app
      config = JSON.parse(File.read('Sources/PastaCore/Resources/ReleaseTrains.json')).fetch(@train)
      @bundle = config.fetch(surface == 'ios' ? 'iosBundleIdentifier' : 'storeMacBundleIdentifier')
      app_attributes = client.get("/v1/apps/#{@app}").dig('data', 'attributes') || {}
      raise 'App record belongs to different identity' unless app_attributes['bundleId'] == @bundle
      # Apple validates external submissions against the app's primary locale
      # (en-GB for Pasta), so TestFlight text is kept complete there too.
      @beta_locales = [BETA_BUILD_LOCALE, app_attributes['primaryLocale']].compact.uniq
    end

    def build
      query = URI.encode_www_form('filter[app]' => @app, 'filter[version]' => @item.fetch('build'),
        'filter[preReleaseVersion.version]' => @item.fetch('version'), 'limit' => 20)
      items = @client.list("/v1/builds?#{query}")
      raise 'Multiple builds match manifest' if items.length > 1
      items.first
    end

    def receipt(status, build, extra = {})
      data = {source: @manifest.fetch('source'), build: @item.fetch('build'), notesHash: @item.fetch('notesHash'),
        status: status, assets: {}, appleBuildID: build&.fetch('id'), checkedAt: Time.now.utc.iso8601}.merge(extra)
      expiry = build&.dig('attributes', 'expirationDate')
      data[:expirationDate] = expiry
      data[:expiresSoon] = !!(expiry && Time.parse(expiry) <= Time.now + 7 * 86_400)
      Dir.mktmpdir('apple-release-') do |dir|
        path = File.join(dir, "#{@surface}-receipt.json")
        File.write(path, JSON.pretty_generate(data) + "\n")
        raise 'Cannot persist Apple receipt' unless retrying { system('gh', 'release', 'upload', @manifest.fetch('tag'), path, '--clobber', '--repo', @repo) }
      end
      puts "#{@surface}: #{status} (#{@item.fetch('version')} #{@item.fetch('build')})"
    end

    # GitHub's upload endpoint returns transient 5xx errors; losing a receipt
    # after a successful Apple upload would fail the whole delivery lane.
    def retrying(attempts: 4, delay: 5)
      attempts.times do |attempt|
        return true if yield
        sleep(delay * (attempt + 1)) if attempt + 1 < attempts
      end
      false
    end

    def distribute(wait_seconds: 600)
      deadline = Time.now + wait_seconds
      loop do
        found = build
        if found && found.dig('attributes', 'processingState') == 'VALID'
          raise 'Expired TestFlight build' if found.dig('attributes', 'expired')
          raise 'Internal-only archive cannot be publicly tested' if @train == 'alpha' && found.dig('attributes', 'buildAudienceType') == 'INTERNAL_ONLY'
          # Stable processing validates the candidate, never distributes a beta.
          return receipt('verified', found, distribution: 'app_store_candidate', groups: []) if @train == 'stable'
          return assign(found)
        end
        if found && %w[FAILED INVALID].include?(found.dig('attributes', 'processingState'))
          receipt('invalid', found)
          raise 'Apple rejected the uploaded binary; allocate a new build attempt'
        end
        if Time.now >= deadline
          receipt('processing', found)
          return
        end
        puts "Waiting for #{@surface} build processing"
        sleep 30
      end
    end

    def assign(found)
      raise 'Only Alpha may be distributed through TestFlight' unless @train == 'alpha'
      id = found.fetch('id')
      ensure_beta_app_description
      ensure_beta_review_detail
      locales = @client.list("/v1/builds/#{id}/betaBuildLocalizations")
      attrs = {whatsNew: @item.fetch('storeNotes')}
      @beta_locales.each do |code|
        locale = locales.find { |l| l.dig('attributes', 'locale') == code }
        if locale
          @client.patch("/v1/betaBuildLocalizations/#{locale['id']}", data: {type: 'betaBuildLocalizations', id: locale['id'], attributes: attrs})
        else
          @client.post('/v1/betaBuildLocalizations', data: {type: 'betaBuildLocalizations', attributes: attrs.merge(locale: code), relationships: {build: AppleRelease.relationship('builds', id)}})
        end
      end
      groups = @client.list("/v1/apps/#{@app}/betaGroups?limit=200")
      targets = groups.select { |g| g.dig('attributes', 'name') == 'Public Alpha' && !g.dig('attributes', 'isInternalGroup') }
      raise 'Expected tester group is missing; do not move existing testers' if targets.empty?
      detail = @client.get("/v1/builds/#{id}/buildBetaDetail").fetch('data')
      state = detail.dig('attributes', 'externalBuildState')
      if @train == 'alpha' && %w[BETA_REJECTED INVALID_BINARY].include?(state)
        receipt('beta_rejected', found, betaState: state)
        raise 'Apple beta review rejected this build; inspect the review feedback before rebuilding'
      end
      if @train == 'alpha' && !%w[IN_BETA_TESTING READY_FOR_BETA_TESTING BETA_APPROVED].include?(state)
        if state == 'READY_FOR_BETA_SUBMISSION'
          query = URI.encode_www_form('filter[app]' => @app, 'filter[betaAppReviewSubmission.betaReviewState]' => 'WAITING_FOR_REVIEW,IN_REVIEW', 'limit' => 200)
          unless @client.list("/v1/builds?#{query}").empty?
            receipt('waiting_for_beta_review_slot', found, betaState: state)
            return
          end
          # Apple enforces six submissions/day. A 409/429 remains pending and
          # the reconciler retries; it must not be reported as public delivery.
          begin
            @client.post('/v1/betaAppReviewSubmissions', data: {type: 'betaAppReviewSubmissions', relationships: {build: AppleRelease.relationship('builds', id)}})
          rescue AppleAPI::ApiError => error
            raise unless [409, 429].include?(error.status)
            receipt('waiting_for_beta_review_slot', found, betaState: state)
            return
          end
        end
        receipt('beta_review_pending', found, betaState: state)
        return
      end
      targets.each do |group|
        assigned = @client.list("/v1/betaGroups/#{group['id']}/builds?limit=200")
        unless assigned.any? { |b| b['id'] == id }
          @client.post("/v1/betaGroups/#{group['id']}/relationships/builds", data: [{type: 'builds', id: id}])
        end
        verified = @client.list("/v1/betaGroups/#{group['id']}/builds?limit=200")
        raise 'Tester assignment was not observed' unless verified.any? { |b| b['id'] == id }
      end
      detail = @client.get("/v1/builds/#{id}/buildBetaDetail").fetch('data')
      state = detail.dig('attributes', 'externalBuildState')
      ready = %w[IN_BETA_TESTING READY_FOR_BETA_TESTING].include?(state)
      receipt(ready ? 'verified' : 'beta_processing', found, betaState: state,
        groups: targets.map { |g| g['id'] }, publicLinks: targets.map { |g| g.dig('attributes', 'publicLink') }.compact, expirationDate: found.dig('attributes', 'expirationDate'))
    end

    def ensure_beta_app_description
      localizations = @client.list("/v1/apps/#{@app}/betaAppLocalizations?limit=200")
      attributes = {
        description: BETA_APP_DESCRIPTION,
        feedbackEmail: BETA_FEEDBACK_EMAIL,
        marketingUrl: BETA_MARKETING_URL,
        privacyPolicyUrl: BETA_PRIVACY_POLICY_URL
      }
      @beta_locales.each do |code|
        localization = localizations.find { |entry| entry.dig('attributes', 'locale') == code }
        if localization
          @client.patch("/v1/betaAppLocalizations/#{localization.fetch('id')}",
            data: {type: 'betaAppLocalizations', id: localization.fetch('id'), attributes: attributes})
        else
          @client.post('/v1/betaAppLocalizations',
            data: {type: 'betaAppLocalizations', attributes: attributes.merge(locale: code),
              relationships: {app: AppleRelease.relationship('apps', @app)}})
        end
      end
    end

    REVIEW_CONTACT_FIELDS = %w[contactFirstName contactLastName contactPhone contactEmail].freeze

    # Apple rejects external beta submission without review contact details.
    # Reuse contact metadata already held in App Store Connect (never stored in
    # the repository): Alpha's own beta detail, then Stable's beta detail, then
    # Stable's App Store review detail, which is where it lives after a normal
    # App Store submission. Pasta has no sign-in, so demo credentials are refused.
    def ensure_beta_review_detail
      target = @client.get("/v1/apps/#{@app}/betaAppReviewDetail").fetch('data')
      candidates = [['Alpha Beta App Review Information', -> { target.fetch('attributes') }],
        ['Stable Beta App Review Information', -> { @client.get("/v1/apps/#{@stable_app}/betaAppReviewDetail").dig('data', 'attributes') }],
        ['Stable App Store Review Information', -> { stable_app_store_review_attributes }]]
      missing_by_source = []
      candidates.each do |label, fetch|
        attributes = fetch.call || {}
        raise "#{label} unexpectedly requires demo credentials" if attributes['demoAccountRequired'] == true
        missing = REVIEW_CONTACT_FIELDS.reject { |key| attributes[key].is_a?(String) && !attributes[key].empty? }
        unless missing.empty?
          missing_by_source << "#{label}: #{missing.join(', ')}"
          next
        end
        update = attributes.select { |key, value| (REVIEW_CONTACT_FIELDS + ['notes']).include?(key) && !value.nil? }
        update['notes'] = target.dig('attributes', 'notes') if update['notes'].nil? && target.dig('attributes', 'notes')
        update['demoAccountRequired'] = false
        current = target.fetch('attributes')
        return if update.all? { |key, value| current[key] == value }
        @client.patch("/v1/betaAppReviewDetails/#{target.fetch('id')}",
          data: {type: 'betaAppReviewDetails', id: target.fetch('id'), attributes: update})
        return
      end
      raise "Beta App Review contact information is incomplete (#{missing_by_source.join('; ')}). Fill in App Store Connect → TestFlight → Test Information for the Alpha app."
    end

    def stable_app_store_review_attributes
      platform = @surface == 'ios' ? 'IOS' : 'MAC_OS'
      versions = @client.list("/v1/apps/#{@stable_app}/appStoreVersions?limit=200").select { |v| v.dig('attributes', 'platform') == platform }
      versions.sort_by { |v| v.dig('attributes', 'createdDate').to_s }.reverse_each do |version|
        detail = @client.get("/v1/appStoreVersions/#{version.fetch('id')}/appStoreReviewDetail")['data']
        return detail['attributes'] if detail && detail['attributes']
      rescue AppleAPI::ApiError => error
        raise unless error.status == 404
      end
      nil
    end

    def observe_publication
      return unless @train == 'stable'
      platform = @surface == 'ios' ? 'IOS' : 'MAC_OS'
      version = @client.list("/v1/apps/#{@app}/appStoreVersions?limit=200").find do |entry|
        entry.dig('attributes','platform') == platform && entry.dig('attributes','versionString') == @item['version']
      end
      return unless version
      state = version.dig('attributes','appStoreState')
      puts "#{@surface} Stable #{@item['version']}: #{state}"
      return unless %w[READY_FOR_SALE READY_FOR_DISTRIBUTION].include?(state)
      attached = @client.get("/v1/appStoreVersions/#{version['id']}/build").fetch('data')
      expected = build
      raise 'Public version does not match candidate build' unless attached['id'] == expected&.fetch('id')
      tag = "published-#{@surface}-v#{@item['version']}-b#{@item['build']}"
      return if system('gh','release','view',tag,'--repo',@repo, out: File::NULL, err: File::NULL)
      Dir.mktmpdir('apple-publication-') do |directory|
        path = File.join(directory,'publication.json')
        File.write(path, JSON.pretty_generate({surface:@surface,source:@manifest['source'],app:@app,
          version:@item['version'],build:@item['build'],state:state,observedAt:Time.now.utc.iso8601}) + "\n")
        raise 'Could not persist publication boundary' unless system('gh','release','create',tag,path,
          '--repo',@repo,'--target',@manifest['source'],'--latest=false','--title',tag,
          '--notes',"Observed public App Store availability for #{@surface}. Candidate #{@manifest['tag']}.")
      end
    end

    # The explicit approval is persisted by Publish Stable before Apple work.
    def owner_approved?
      Dir.mktmpdir do |dir|
        return false unless system('gh','release','download',@manifest['tag'],'--repo',@repo,'--pattern','approval.json','--dir',dir, out: File::NULL, err: File::NULL)
        approval = JSON.parse(File.read(File.join(dir,'approval.json')))
        expected = Digest::SHA256.hexdigest(JSON.pretty_generate(@manifest) + "\n")
        # Node and Ruby format JSON identically for this manifest (two spaces).
        approval['manifestHash'] == expected && approval['actor'] == @repo.split('/').first
      end
    end

    # The approved Sparkle release is public and points at the frozen source.
    def direct_release_published?
      tag = "v#{@manifest.dig('surfaces','mac-direct','version')}"
      out, status = Open3.capture2('gh','release','view',tag,'--repo',@repo,'--json','isDraft,isPrerelease', err: File::NULL)
      return false unless status.success?
      info = JSON.parse(out)
      return false if info['isDraft'] || info['isPrerelease']
      sha, status = Open3.capture2('gh','api',"repos/#{@repo}/commits/#{tag}",'--jq','.sha', err: File::NULL)
      status.success? && sha.strip == @manifest['source']
    end

    SUBMITTABLE_STATES = %w[PREPARE_FOR_SUBMISSION].freeze
    HALTED_STATES = %w[REJECTED METADATA_REJECTED DEVELOPER_REJECTED INVALID_BINARY].freeze

    # Stable iOS follows the Sparkle release asynchronously: submit once the
    # owner approved the candidate, the direct release is public and Apple has
    # processed the build. Rejections wait for a human; they are never resubmitted.
    def submit_if_ready
      raise 'Alpha must never enter App Store review' unless @train == 'stable'
      return pending('awaiting owner approval') unless owner_approved?
      return pending('awaiting public direct Mac release') unless direct_release_published?
      found = build
      return pending('no uploaded Stable build') unless found
      state = found.dig('attributes', 'processingState')
      return pending("Apple processing is #{state}") unless state == 'VALID'
      platform = @surface == 'ios' ? 'IOS' : 'MAC_OS'
      version = @client.list("/v1/apps/#{@app}/appStoreVersions?limit=200").find do |v|
        v.dig('attributes','platform') == platform && v.dig('attributes','versionString') == @item['version']
      end
      app_state = version&.dig('attributes','appStoreState')
      if HALTED_STATES.include?(app_state)
        puts "::warning::#{@surface} Stable #{@item['version']} is #{app_state}; resolve it in App Store Connect"
        return false
      end
      return pending("App Store version is #{app_state}") if app_state && !SUBMITTABLE_STATES.include?(app_state)
      submit
      true
    end

    def pending(reason)
      puts "#{@surface} Stable #{@item['version']} submission pending: #{reason}"
      false
    end

    def submit
      raise 'Alpha must never enter App Store review' unless @train == 'stable'
      raise 'Missing owner approval or approval hash/owner mismatch' unless owner_approved?
      found = build
      raise 'Stable binary has not processed' unless found&.dig('attributes', 'processingState') == 'VALID'
      platform = @surface == 'ios' ? 'IOS' : 'MAC_OS'
      versions = @client.list("/v1/apps/#{@app}/appStoreVersions?limit=200").select { |v| v.dig('attributes','platform') == platform }
      version = versions.find { |v| v.dig('attributes','versionString') == @item['version'] }
      unless version
        rejected = versions.find { |v| %w[PREPARE_FOR_SUBMISSION REJECTED DEVELOPER_REJECTED].include?(v.dig('attributes','appStoreState')) }
        version = if rejected
          @client.patch("/v1/appStoreVersions/#{rejected['id']}", data: {type:'appStoreVersions',id:rejected['id'],attributes:{versionString:@item['version'],releaseType:'AFTER_APPROVAL'}})['data']
        else
          @client.post('/v1/appStoreVersions', data:{type:'appStoreVersions',attributes:{platform:platform,versionString:@item['version'],releaseType:'AFTER_APPROVAL'},relationships:{app:AppleRelease.relationship('apps',@app)}})['data']
        end
      end
      id=version.fetch('id')
      if %w[WAITING_FOR_REVIEW IN_REVIEW READY_FOR_SALE READY_FOR_DISTRIBUTION].include?(version.dig('attributes','appStoreState'))
        attached=@client.get("/v1/appStoreVersions/#{id}/build").dig('data','id')
        raise 'Existing submission is a different candidate' unless attached == found['id']
        puts "#{@surface}: existing submission #{version.dig('attributes','appStoreState')}"
        return
      end
      @client.patch("/v1/appStoreVersions/#{id}", data:{type:'appStoreVersions',id:id,attributes:{releaseType:'AFTER_APPROVAL'},relationships:{build:AppleRelease.relationship('builds',found['id'])}})
      locales=@client.list("/v1/appStoreVersions/#{id}/appStoreVersionLocalizations")
      raise 'App Store localisation missing' if locales.empty?
      locales.each do |locale|
        # Notes are reviewed English copy. Do not silently overwrite translations.
        next unless locale.dig('attributes','locale').start_with?('en')
        @client.patch("/v1/appStoreVersionLocalizations/#{locale['id']}", data:{type:'appStoreVersionLocalizations',id:locale['id'],attributes:{whatsNew:@item['storeNotes']}})
      end
      submissions=@client.list("/v1/apps/#{@app}/reviewSubmissions?limit=200")
      review=submissions.find { |r| r.dig('attributes','platform') == platform && r.dig('attributes','state') == 'READY_FOR_REVIEW' }
      review ||= @client.post('/v1/reviewSubmissions',data:{type:'reviewSubmissions',attributes:{platform:platform},relationships:{app:AppleRelease.relationship('apps',@app)}})['data']
      items=@client.list("/v1/reviewSubmissions/#{review['id']}/items")
      raise 'Existing review contains another submission item' if items.any? { |i| i.dig('relationships','appStoreVersion','data','id') != id }
      if items.empty?
        @client.post('/v1/reviewSubmissionItems',data:{type:'reviewSubmissionItems',relationships:{reviewSubmission:AppleRelease.relationship('reviewSubmissions',review['id']),appStoreVersion:AppleRelease.relationship('appStoreVersions',id)}})
      end
      @client.patch("/v1/reviewSubmissions/#{review['id']}",data:{type:'reviewSubmissions',id:review['id'],attributes:{submitted:true}})
      observed=@client.get("/v1/reviewSubmissions/#{review['id']}").dig('data','attributes','state')
      raise "Review submission not observed: #{observed}" unless %w[WAITING_FOR_REVIEW IN_REVIEW COMPLETE].include?(observed)
      puts "#{@surface}: #{observed}; releaseType AFTER_APPROVAL; public availability remains pending"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  command, path, surface = ARGV
  manifest = JSON.parse(File.read(path))
  delivery = AppleRelease::Delivery.new(client: AppleRelease::Client.new, manifest: manifest, surface: surface)
  case command
  when 'distribute' then delivery.distribute
  when 'reconcile' then delivery.distribute(wait_seconds: 0)
  when 'upload-status'
    existing = delivery.build
    if existing && %w[INVALID FAILED].include?(existing.dig('attributes','processingState'))
      abort 'Existing Apple upload failed; allocate a new attempt instead of uploading duplicate build numbers'
    end
    File.open(ENV.fetch('GITHUB_OUTPUT'), 'a') { |file| file.puts("skip_upload=#{!existing.nil?}") }
  when 'observe' then delivery.observe_publication
  when 'submit' then delivery.submit
  when 'submit-if-ready' then delivery.submit_if_ready
  else abort 'Usage: release-apple.rb distribute|reconcile|upload-status|observe|submit|submit-if-ready manifest.json ios|mac-store'
  end
end
