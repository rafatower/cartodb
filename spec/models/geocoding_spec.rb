#encoding: UTF-8
require 'spec_helper'
require 'ruby-debug'

describe Geocoding do
  before(:all) do
    @user  = create_user(geocoding_quota: 200, geocoding_block_price: 1500)
    @table = FactoryGirl.create(:table, user_id: @user.id)
  end

  before(:each) do
    CartoDB::NamedMapsWrapper::NamedMaps.any_instance.stubs(:get).returns(nil)
  end

  after(:all) do
    CartoDB::Visualization::Member.any_instance.stubs(:has_named_map?).returns(false)
    @user.destroy
  end

  describe '#setup' do
    let(:geocoding) { FactoryGirl.create(:geocoding, user: @user, table: @table) }

    it 'sets default timestamps value' do
      geocoding.created_at.should_not be_nil
      geocoding.updated_at.should_not be_nil
    end

    it 'links user and geocoding' do
      geocoding.user.should eq @user
    end
  end

  describe '#table_geocoder' do
    it 'returns an instance of TableGeocoder when kind is high-resolution' do
      geocoding = FactoryGirl.build(:geocoding, user: @user, table: @table, kind: 'high-resolution')
      geocoding.table_geocoder.should be_kind_of(CartoDB::TableGeocoder)
    end

    it 'returns an instance of InternalGeocoder when kind is not high-resolution' do
      geocoding = FactoryGirl.build(:geocoding, user: @user, table: @table, kind: 'admin0', geometry_type: 'polygon')
      geocoding.table_geocoder.should be_kind_of(CartoDB::InternalGeocoder::Geocoder)
    end

    it 'memoizes' do
      geocoding = FactoryGirl.build(:geocoding, user: @user, table: @table, kind: 'admin0', geometry_type: 'polygon')
      geocoder = geocoding.table_geocoder
      geocoder.should be_kind_of(CartoDB::InternalGeocoder::Geocoder)
      geocoder.should eq geocoding.table_geocoder
    end
  end

  describe '#save' do
    let(:geocoding) { FactoryGirl.build(:geocoding, user: @user, table: @table) }

    it 'validates formatter' do
      geocoding.raise_on_save_failure = true
      expect { geocoding.save }.to raise_error(Sequel::ValidationFailed)
      geocoding.errors[:formatter].join(',').should match /is not present/
    end

    it 'validates kind' do
      geocoding.raise_on_save_failure = true
      geocoding.kind = 'nonsense'
      expect { geocoding.save }.to raise_error(Sequel::ValidationFailed)
      geocoding.errors[:kind].join(',').should match /is not in range or set/
    end

    it 'updates updated_at' do
      geocoding = FactoryGirl.build(:geocoding, user: @user, table: @table, formatter: 'b', kind: 'admin0')
      expect { geocoding.save }.to change(geocoding, :updated_at)
    end
  end

  describe '#translate_formatter' do
    let(:geocoding) { FactoryGirl.build(:geocoding, user: @user, table: @table) }

    it 'translates a string with field names' do
      geocoding.formatter = '{a}, {b}'
      geocoding.translate_formatter.should == "a, ', ', b"
    end

    it 'translates a string with literals' do
      geocoding.formatter = 'c'
      geocoding.translate_formatter.should == "'c'"
    end

    it 'translates a string with mixed literals and field names' do
      geocoding.formatter = '{a}, b, {c}'
      geocoding.translate_formatter.should == "a, ', b, ', c"
    end
  end

  describe '#run!' do
    it 'updates geocoding stats' do
      geocoding = FactoryGirl.create(:geocoding, user: @user, table: @table, formatter: 'b')
      geocoding.table_geocoder.stubs(:run).returns true
      geocoding.table_geocoder.stubs(:cache).returns  OpenStruct.new(hits: 5000)
      geocoding.table_geocoder.stubs(:process_results).returns true
      geocoding.class.stubs(:processable_rows).returns 10
      CartoDB::Geocoder.any_instance.stubs(:status).returns 'completed'
      CartoDB::Geocoder.any_instance.stubs(:update_status).returns true
      CartoDB::Geocoder.any_instance.stubs(:processed_rows).returns 10
      geocoding.run!
      geocoding.processed_rows.should eq 10
      geocoding.state.should eq 'finished'
      geocoding.cache_hits.should eq 5000
      geocoding.used_credits.should eq 4810
    end

    it 'marks the geocoding as failed if the geocoding job fails' do
      geocoding = FactoryGirl.build(:geocoding, user: @user, formatter: 'a', table: @table, formatter: 'b')
      geocoding.class.stubs(:processable_rows).returns 10
      CartoDB::TableGeocoder.any_instance.stubs(:run).raises("Error")
      CartoDB.expects(:notify_exception).times(1)

      geocoding.run!
      geocoding.state.should eq 'failed'
    end

    it 'raises a timeout error if geocoding takes more than 15 minutes to start' do
      geocoding = FactoryGirl.create(:geocoding, user: @user, table: @table, formatter: 'b')
      geocoding.class.stubs(:processable_rows).returns 10
      CartoDB::TableGeocoder.any_instance.stubs(:run).returns true
      CartoDB::TableGeocoder.any_instance.stubs(:process_results).returns true
      CartoDB::Geocoder.any_instance.stubs(:status).returns 'submitted'
      CartoDB::Geocoder.any_instance.stubs(:update_status).returns true
      geocoding.run_timeout = 0.1
      geocoding.run!
      geocoding.reload.state.should eq 'failed'
      geocoding.run_timeout = Geocoding::DEFAULT_TIMEOUT
    end

    it 'succeeds if there are no rows to geocode' do
      geocoding = FactoryGirl.build(:geocoding, user: @user, formatter: 'a', table: @table, formatter: 'b')
      geocoding.class.stubs(:processable_rows).returns 0
      geocoding.run!
      geocoding.processed_rows.should eq 0
      geocoding.state.should eq 'finished'
      geocoding.cache_hits.should eq 0
      geocoding.used_credits.should eq 0
    end

    pending 'creates an automatic geocoder' do
      geocoding = Geocoding.create(user: @user, table: @table, formatter: 'b')
      CartoDB::TableGeocoder.any_instance.stubs(:run).returns true
      CartoDB::TableGeocoder.any_instance.stubs(:process_results).returns true
      CartoDB::Geocoder.any_instance.stubs(:status).returns 'completed'
      CartoDB::Geocoder.any_instance.stubs(:update_status).returns true
      CartoDB.expects(:notify_exception).once.returns(true)
      expect { geocoding.run! }.to change { AutomaticGeocoding.count }.by(1)
      geocoding.automatic_geocoding_id.should_not be_nil
    end
  end

  describe '#max_geocodable_rows' do
    let(:geocoding) { FactoryGirl.build(:geocoding, user: @user) }

    it 'returns the remaining quota if the user has hard limit' do
      @user.stubs('hard_geocoding_limit?').returns(true)
      delete_user_data @user
      geocoding.max_geocodable_rows.should eq 200
      FactoryGirl.create(:geocoding, user: @user, processed_rows: 100, remote_id: 'wadus')
      geocoding.max_geocodable_rows.should eq 100
    end

    it 'returns nil if the user has soft limit' do
      @user.stubs('soft_geocoding_limit?').returns(true)
      FactoryGirl.create(:geocoding, user: @user, processed_rows: 100)
      geocoding.max_geocodable_rows.should eq nil
    end

    it 'returns the remaining quota for the organization if the user has hard limit and belongs to an org' do
      organization = create_organization_with_users(:geocoding_quota => 150)
      org_user = organization.users.last
      org_user.stubs('soft_geocoding_limit?').returns(false)
      org_geocoding = FactoryGirl.build(:geocoding, user: org_user)
      organization.geocoding_quota.should eq 150
      org_geocoding.max_geocodable_rows.should eq 150
      FactoryGirl.create(:geocoding, user: org_user, processed_rows: 100, remote_id: 'wadus')
      org_geocoding.max_geocodable_rows.should eq 50
      organization.destroy
    end

  end

  describe '#cancel' do
    let(:geocoding) { FactoryGirl.build(:geocoding, user: @user) }

    it 'cancels the geocoding job' do
      geocoding.table_geocoder.expects(:cancel).times(1).returns(true)
      geocoding.cancel
    end

    it 'tries 5 times to cancel the geocoding job if that fails and after that sends an error report' do
      CartoDB.expects(:notify_exception).times(1)
      geocoding.table_geocoder.expects(:cancel).times(5).raises("error")
      geocoding.cancel
    end
  end

  describe '#calculate_used_credits' do
    before(:each) do
      @user.geocodings_dataset.delete
    end

    it 'returns 0 when the geocode is not high-resolution' do
      geocoding = FactoryGirl.create(:geocoding, user: @user, kind: 'admin0', processed_rows: 10500)
      geocoding.calculate_used_credits.should eq 0
    end

    it 'returns 0 when the user has enough quota' do
      # User has 200 geocoding credits, so geocoding 200 strings should take 0 credits
      geocoding = FactoryGirl.create(:geocoding, user: @user, processed_rows: 0, cache_hits: 200, kind: 'high-resolution')
      geocoding.calculate_used_credits.should eq 0
    end

    it 'returns the used credits when the user is over geocoding quota' do
      geocoding = FactoryGirl.create(:geocoding, user: @user, processed_rows: 0, cache_hits: 100, kind: 'high-resolution')
      # 100 total (user has 200) => 0 used credits
      geocoding.calculate_used_credits.should eq 0
      geocoding = FactoryGirl.create(:geocoding, user: @user, processed_rows: 0, cache_hits: 150, kind: 'high-resolution')
      # 250 total => 50 used credits
      geocoding.calculate_used_credits.should eq 50
      geocoding = FactoryGirl.create(:geocoding, user: @user, processed_rows: 100, cache_hits: 0, kind: 'high-resolution')
      # 350 total => 100 used credits
      geocoding.calculate_used_credits.should eq 100
    end
  end

  describe '#price' do
    it 'returns 0 when the job used no credits' do
      geocoding = FactoryGirl.create(:geocoding, user: @user, used_credits: 0)
      geocoding.price.should eq 0
    end

    it 'returns the expected price when the geocoding used some credits' do
      geocoding = FactoryGirl.create(:geocoding, user: @user, used_credits: 100)
      geocoding.price.should eq 150
      geocoding = FactoryGirl.create(:geocoding, user: @user, used_credits: 3)
      geocoding.price.should eq 4.5
    end
  end

  describe '#failed_rows and #successful_rows' do
    before(:each) do
      @user.geocodings_dataset.delete
    end
    it 'returns expected results' do
      geocoding = FactoryGirl.create(:geocoding, user: @user, processed_rows: 0, cache_hits: 100, real_rows: 100, processable_rows: 100, kind: 'high-resolution')
      geocoding.failed_rows.should eq 0
      geocoding.successful_rows.should eq 100
      geocoding = FactoryGirl.create(:geocoding, user: @user, processed_rows: 10, cache_hits: 150, real_rows: 155, processable_rows: 160, kind: 'high-resolution')
      geocoding.failed_rows.should eq 5
      geocoding.successful_rows.should eq 155
      geocoding = FactoryGirl.create(:geocoding, user: @user, processed_rows: 100, cache_hits: 0, real_rows: 100, processable_rows: 100, kind: 'high-resolution')
      geocoding.failed_rows.should eq 0
      geocoding.successful_rows.should eq 100
      geocoding = FactoryGirl.create(:geocoding, user: @user, processed_rows: 0, cache_hits: 0, real_rows: 0, processable_rows: 0, kind: 'high-resolution')
      geocoding.failed_rows.should eq 0
      geocoding.successful_rows.should eq 0
      geocoding = FactoryGirl.create(:geocoding, user: @user, processed_rows: 100, cache_hits: 0, real_rows: 0, processable_rows: 100, kind: 'high-resolution')
      geocoding.failed_rows.should eq 100
      geocoding.successful_rows.should eq 0
    end
  end

  describe '#successful_rows' do

  end
end
