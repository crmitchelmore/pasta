require 'minitest/autorun'
require_relative '../release-apple'

class ReleaseAppleTest < Minitest::Test
  class FakeClient
    attr_accessor :processing, :beta_state, :review_busy, :assigned, :bundle_id, :app_localization, :review_source, :store_review, :primary_locale
    attr_reader :posts, :patches, :post_bodies, :patch_bodies, :events
    def initialize
      @bundle_id='com.pasta.ios.alpha'; @processing='VALID'; @beta_state='READY_FOR_BETA_SUBMISSION'; @review_busy=false; @assigned=false
      @app_localization=nil
      @review_source={'id'=>'stable-review','attributes'=>{'contactFirstName'=>'Test','contactLastName'=>'Reviewer','contactPhone'=>'+441234567890','contactEmail'=>'review@example.com','demoAccountRequired'=>false,'notes'=>'No sign-in required.'}}
      @store_review=nil
      @posts=[]; @patches=[]; @post_bodies=[]; @patch_bodies=[]; @events=[]
    end
    def build
      {'id'=>'apple-build','attributes'=>{'processingState'=>processing,'expired'=>false,'expirationDate'=>'2026-12-01T00:00:00Z'}}
    end
    def get(path)
      if path.end_with?('/betaAppReviewDetail')
        return {'data'=>review_source} if path.include?('/6759037470/')
        return {'data'=>{'id'=>'alpha-review','attributes'=>{}}}
      end
      return {'data'=>(store_review && {'id'=>'stable-store-review','attributes'=>store_review})} if path.end_with?('/appStoreReviewDetail')
      return {'data'=>{'attributes'=>{'bundleId'=>bundle_id,'primaryLocale'=>primary_locale}}} if path.start_with?('/v1/apps/')
      {'data'=>{'attributes'=>{'externalBuildState'=>assigned ? 'IN_BETA_TESTING' : beta_state}}}
    end
    def list(path)
      if path.start_with?('/v1/builds?')
        return review_busy ? [build] : [] if path.include?('betaAppReviewSubmission')
        return [build]
      end
      return [app_localization].flatten.compact if path.include?('/betaAppLocalizations')
      return [] if path.end_with?('/betaBuildLocalizations')
      return [{'id'=>'stable-version','attributes'=>{'platform'=>'IOS','versionString'=>'1.8.0','createdDate'=>'2026-09-01T00:00:00Z'}}] if path.include?('/6759037470/appStoreVersions')
      return [{'id'=>'public-alpha','attributes'=>{'name'=>'Public Alpha','isInternalGroup'=>false,'publicLink'=>'https://testflight.apple.com/join/example'}}] if path.include?('/apps/')
      assigned ? [build] : []
    end
    def post(path, body)
      @posts << path; @post_bodies << body; @events << [:post, path]
      @assigned=true if path.end_with?('/relationships/builds')
      {'data'=>{}}
    end
    def patch(path, body); @patches << path; @patch_bodies << body; @events << [:patch, path]; {'data'=>{}}; end
  end
  class Delivery < AppleRelease::Delivery
    attr_reader :receipts
    def receipt(status, build, extra={})
      (@receipts ||= []) << [status,extra]
    end
  end
  def delivery(client, train: 'alpha')
    notes='Frozen notes'
    manifest={'train'=>train,'source'=>'a'*40,'tag'=>'alpha-build-1','surfaces'=>{'ios'=>{'version'=>'3.2.0','build'=>'1000.0.1','notes'=>notes,'notesHash'=>Digest::SHA256.hexdigest(notes),'storeNotes'=>notes,'storeNotesHash'=>Digest::SHA256.hexdigest(notes)}}}
    Delivery.new(client:client,manifest:manifest,surface:'ios')
  end
  def test_stable_candidate_never_assigns_testers
    client=FakeClient.new; client.bundle_id=client.bundle_id.delete_suffix('.alpha')
    d=delivery(client, train: 'stable'); d.distribute(wait_seconds:0)
    assert_equal 'verified', d.receipts.last.first
    assert_equal 'app_store_candidate', d.receipts.last.last[:distribution]
    assert_empty d.receipts.last.last[:groups]
    assert_empty client.posts
    refute client.assigned
    assert_raises(RuntimeError) { d.assign(client.build) }
  end
  def test_alpha_cannot_enter_app_store_review
    client=FakeClient.new
    error=assert_raises(RuntimeError) { delivery(client).submit }
    assert_match 'Alpha must never enter App Store review', error.message
    assert_empty client.posts
  end
  def test_processing_is_pending_not_delivery
    client=FakeClient.new;client.processing='PROCESSING';d=delivery(client);d.distribute(wait_seconds:0)
    assert_equal 'processing',d.receipts.last.first
    assert_empty client.posts
  end
  def test_busy_review_slot_preserves_pending_build
    client=FakeClient.new;client.review_busy=true;d=delivery(client);d.distribute(wait_seconds:0)
    assert_equal 'waiting_for_beta_review_slot',d.receipts.last.first
    refute client.posts.any?{|path|path.end_with?('/betaAppReviewSubmissions')}
    refute client.assigned
  end
  def test_approved_build_requires_observed_group_assignment
    client=FakeClient.new;client.beta_state='BETA_APPROVED';d=delivery(client);d.distribute(wait_seconds:0)
    assert client.assigned
    assert_equal 'verified',d.receipts.last.first
    assert_equal ['https://testflight.apple.com/join/example'],d.receipts.last.last[:publicLinks]
  end
  def test_alpha_sets_beta_app_description_before_review_submission
    client=FakeClient.new;delivery(client).distribute(wait_seconds:0)
    index=client.posts.index('/v1/betaAppLocalizations')
    review_index=client.posts.index('/v1/betaAppReviewSubmissions')
    refute_nil index
    refute_nil review_index
    assert_operator index, :<, review_index
    assert_equal AppleRelease::BETA_APP_DESCRIPTION, client.post_bodies[index].dig(:data, :attributes, :description)
    assert_equal AppleRelease::BETA_FEEDBACK_EMAIL, client.post_bodies[index].dig(:data, :attributes, :feedbackEmail)
    assert_equal AppleRelease::BETA_MARKETING_URL, client.post_bodies[index].dig(:data, :attributes, :marketingUrl)
    assert_equal AppleRelease::BETA_PRIVACY_POLICY_URL, client.post_bodies[index].dig(:data, :attributes, :privacyPolicyUrl)
    build_localization = client.post_bodies.find.with_index do |body, body_index|
      client.posts[body_index] == '/v1/betaBuildLocalizations'
    end
    assert_equal AppleRelease::BETA_BUILD_LOCALE, build_localization.dig(:data, :attributes, :locale)
  end
  def test_alpha_copies_stable_beta_review_information_before_submission
    client=FakeClient.new;delivery(client).distribute(wait_seconds:0)
    patch_index=client.events.index([:patch, '/v1/betaAppReviewDetails/alpha-review'])
    review_index=client.events.index([:post, '/v1/betaAppReviewSubmissions'])
    refute_nil patch_index
    refute_nil review_index
    assert_operator patch_index, :<, review_index
    body_index=client.patches.index('/v1/betaAppReviewDetails/alpha-review')
    assert_equal client.review_source['attributes'], client.patch_bodies[body_index].dig(:data, :attributes)
  end
  def test_alpha_refuses_review_metadata_that_requires_demo_credentials
    client=FakeClient.new
    client.review_source['attributes']['demoAccountRequired']=true
    client.review_source['attributes']['demoAccountName']='masked-user'
    client.review_source['attributes']['demoAccountPassword']='********'
    error=assert_raises(RuntimeError){delivery(client).distribute(wait_seconds:0)}
    assert_match 'unexpectedly requires demo credentials', error.message
    refute_includes client.posts, '/v1/betaAppReviewSubmissions'
  end
  def test_alpha_refuses_incomplete_stable_beta_review_information
    client=FakeClient.new
    client.review_source={'id'=>'stable-review','attributes'=>{'contactEmail'=>'review@example.com','demoAccountRequired'=>false}}
    error=assert_raises(RuntimeError){delivery(client).distribute(wait_seconds:0)}
    assert_match 'Stable Beta App Review Information: contactFirstName, contactLastName, contactPhone', error.message
    assert_match 'Stable App Store Review Information', error.message
    refute_includes client.posts, '/v1/betaAppReviewSubmissions'
    refute_includes client.patches, '/v1/betaAppReviewDetails/alpha-review'
  end
  def test_alpha_falls_back_to_stable_app_store_review_contact
    client=FakeClient.new
    client.review_source={'id'=>'stable-review','attributes'=>{'contactFirstName'=>nil,'contactLastName'=>nil,'contactPhone'=>nil,'contactEmail'=>nil,'demoAccountRequired'=>nil,'notes'=>nil}}
    client.store_review={'contactFirstName'=>'Store','contactLastName'=>'Reviewer','contactPhone'=>'+441234567890','contactEmail'=>'store@example.com','demoAccountName'=>nil,'demoAccountPassword'=>nil,'demoAccountRequired'=>false,'notes'=>'No sign-in required.'}
    delivery(client).distribute(wait_seconds:0)
    patch_index=client.events.index([:patch, '/v1/betaAppReviewDetails/alpha-review'])
    review_index=client.events.index([:post, '/v1/betaAppReviewSubmissions'])
    refute_nil patch_index
    refute_nil review_index
    assert_operator patch_index, :<, review_index
    body=client.patch_bodies[client.patches.index('/v1/betaAppReviewDetails/alpha-review')].dig(:data, :attributes)
    assert_equal({'contactFirstName'=>'Store','contactLastName'=>'Reviewer','contactPhone'=>'+441234567890','contactEmail'=>'store@example.com','notes'=>'No sign-in required.','demoAccountRequired'=>false}, body)
  end
  def test_alpha_treats_unset_demo_requirement_as_not_required
    client=FakeClient.new
    client.review_source['attributes']['demoAccountRequired']=nil
    delivery(client).distribute(wait_seconds:0)
    body=client.patch_bodies[client.patches.index('/v1/betaAppReviewDetails/alpha-review')].dig(:data, :attributes)
    assert_equal false, body['demoAccountRequired']
    assert_includes client.posts, '/v1/betaAppReviewSubmissions'
  end
  def test_alpha_updates_existing_beta_app_description
    client=FakeClient.new
    client.app_localization={'id'=>'existing-localization','attributes'=>{'locale'=>'en-US','description'=>'Old description'}}
    delivery(client).distribute(wait_seconds:0)
    assert_includes client.patches, '/v1/betaAppLocalizations/existing-localization'
    index=client.patches.index('/v1/betaAppLocalizations/existing-localization')
    assert_equal AppleRelease::BETA_APP_DESCRIPTION, client.patch_bodies[index].dig(:data, :attributes, :description)
    assert_equal AppleRelease::BETA_FEEDBACK_EMAIL, client.patch_bodies[index].dig(:data, :attributes, :feedbackEmail)
    assert_equal AppleRelease::BETA_MARKETING_URL, client.patch_bodies[index].dig(:data, :attributes, :marketingUrl)
    assert_equal AppleRelease::BETA_PRIVACY_POLICY_URL, client.patch_bodies[index].dig(:data, :attributes, :privacyPolicyUrl)
    refute_includes client.posts, '/v1/betaAppLocalizations'
  end
  def test_alpha_creates_default_english_beta_app_localization
    client=FakeClient.new
    delivery(client).distribute(wait_seconds:0)
    index=client.posts.index('/v1/betaAppLocalizations')
    assert_equal 'en-US', client.post_bodies[index].dig(:data, :attributes, :locale)
  end
  def test_alpha_completes_primary_locale_beta_information
    client=FakeClient.new
    client.primary_locale='en-GB'
    client.app_localization=[{'id'=>'gb-localization','attributes'=>{'locale'=>'en-GB','description'=>'Old description'}}]
    delivery(client).distribute(wait_seconds:0)
    gb=client.patch_bodies[client.patches.index('/v1/betaAppLocalizations/gb-localization')].dig(:data, :attributes)
    assert_equal AppleRelease::BETA_FEEDBACK_EMAIL, gb[:feedbackEmail]
    assert_equal AppleRelease::BETA_PRIVACY_POLICY_URL, gb[:privacyPolicyUrl]
    us=client.post_bodies[client.posts.index('/v1/betaAppLocalizations')].dig(:data, :attributes)
    assert_equal 'en-US', us[:locale]
    build_locales=client.post_bodies.each_with_index.select { |_, i| client.posts[i] == '/v1/betaBuildLocalizations' }.map { |b, _| b.dig(:data, :attributes, :locale) }
    assert_equal %w[en-US en-GB], build_locales
    assert_operator client.events.index([:patch, '/v1/betaAppLocalizations/gb-localization']), :<, client.events.index([:post, '/v1/betaAppReviewSubmissions'])
  end
  def test_rejected_beta_is_actionable_not_indefinitely_pending
    client=FakeClient.new;client.beta_state='BETA_REJECTED';d=delivery(client)
    assert_raises(RuntimeError){d.distribute(wait_seconds:0)}
    assert_equal 'beta_rejected',d.receipts.last.first
    refute client.assigned
  end
  def test_receipt_persistence_retries_transient_upload_failures
    d=delivery(FakeClient.new)
    results=[false,false,true]
    assert d.retrying(delay: 0) { results.shift }
    calls=0
    refute d.retrying(attempts: 3, delay: 0) { calls+=1; false }
    assert_equal 3, calls
  end
  def test_invalid_upload_requires_a_new_build_number
    client=FakeClient.new;client.processing='INVALID';d=delivery(client)
    assert_raises(RuntimeError){d.distribute(wait_seconds:0)}
    assert_equal 'invalid',d.receipts.last.first
  end
  class GatedDelivery < Delivery
    attr_accessor :approved, :published, :submitted
    def owner_approved?; approved; end
    def direct_release_published?; published; end
    def submit; @submitted = true; end
  end
  def gated(client, approved: true, published: true)
    client.bundle_id=client.bundle_id.delete_suffix('.alpha')
    notes='Frozen notes'
    manifest={'train'=>'stable','source'=>'a'*40,'tag'=>'stable-candidate-1','surfaces'=>{'mac-direct'=>{'version'=>'3.2.0'},'ios'=>{'version'=>'3.2.0','build'=>'1000.0.1','notes'=>notes,'notesHash'=>Digest::SHA256.hexdigest(notes),'storeNotes'=>notes,'storeNotesHash'=>Digest::SHA256.hexdigest(notes)}}}
    d=GatedDelivery.new(client:client,manifest:manifest,surface:'ios'); d.approved=approved; d.published=published; d
  end
  def test_stable_ios_submission_waits_for_approval_sparkle_and_processing
    refute gated(FakeClient.new, approved: false).submit_if_ready
    refute gated(FakeClient.new, published: false).submit_if_ready
    client=FakeClient.new; client.processing='PROCESSING'; d=gated(client)
    refute d.submit_if_ready
    refute d.submitted
  end
  def test_stable_ios_submits_asynchronously_once_ready
    d=gated(FakeClient.new)
    assert d.submit_if_ready
    assert d.submitted
  end
  def test_stable_ios_never_resubmits_rejected_or_active_reviews
    %w[REJECTED METADATA_REJECTED WAITING_FOR_REVIEW READY_FOR_SALE].each do |state|
      client=FakeClient.new
      client.define_singleton_method(:list) do |path|
        next [{'id'=>'v','attributes'=>{'platform'=>'IOS','versionString'=>'3.2.0','appStoreState'=>state}}] if path.include?('/appStoreVersions')
        super(path)
      end
      d=gated(client)
      refute d.submit_if_ready, state
      refute d.submitted, state
    end
  end
  def test_alpha_never_submits_through_async_gate
    assert_raises(RuntimeError) { delivery(FakeClient.new).submit_if_ready }
  end
end
