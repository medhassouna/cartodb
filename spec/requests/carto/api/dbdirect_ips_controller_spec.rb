require 'spec_helper_min'
require 'support/helpers'
require 'helpers/feature_flag_helper'
require 'spec_helper'

class TestFirewallManager
  @rules = {}
  @config = nil
  class <<self
    attr_reader :rules, :config
    attr_writer :config
  end

  def initialize(config)
    @config = config
    TestFirewallManager.config = config
  end

  attr_reader :config

  def replace_rule(rule_id, ips)
    TestFirewallManager.rules[rule_id] = ips
  end
end

class TestErrorFirewallManager
  def initialize(config)
  end
  def replace_rule(rule_id, ips)
    raise "FIREWALL ERROR"
  end
end

describe Carto::Api::DbdirectIpsController do
  include_context 'users helper'
  include HelperMethods
  include FeatureFlagHelper
  include Rack::Test::Methods

  before(:all) do
    host! "#{@carto_user1.username}.localhost.lan"
    @feature_flag = FactoryGirl.create(:feature_flag, name: 'dbdirect', restricted: true)
    @config = {
      firewall: 'the-config'
    }.with_indifferent_access

    @sequel_organization = FactoryGirl.create(:organization_with_users)
    @organization = Carto::Organization.find(@sequel_organization.id)
    @org_owner = @organization.owner
    @org_user = @organization.users.reject { |u| u.id == @organization.owner_id }.first
  end

  after(:all) do
    @feature_flag.destroy
    @organization.destroy
  end

  after(:each) do
    logout
  end

  describe '#update' do
    before(:each) do
      @params = { api_key: @carto_user1.api_key }
      Carto::DbdirectIp.stubs(:firewall_manager_class).returns(TestFirewallManager)
    end

    after(:each) do
      Carto::DbdirectIp.delete_all
      TestFirewallManager.rules.clear
      TestFirewallManager.config = nil
    end

    it 'needs authentication for ips creation' do
      params = {
        ips: ['100.20.30.40']
      }
      Cartodb.with_config dbdirect: @config do
        put_json(dbdirect_ip_url, params) do |response|
          expect(response.status).to eq(401)
          expect(@carto_user1.reload.dbdirect_effective_ips).to be_empty
          expect(TestFirewallManager.rules[@carto_user1.username]).to be_nil
        end
      end
    end

    it 'needs the feature flag for ips creation' do
        params = {
          ips: ['100.20.30.40'],
          api_key: @carto_user1.api_key
        }
        with_feature_flag @carto_user1, 'dbdirect', false do
          Cartodb.with_config dbdirect: @config do
            put_json(dbdirect_ip_url, params) do |response|
              expect(response.status).to eq(403)
              expect(@carto_user1.reload.dbdirect_effective_ips).to be_empty
              expect(TestFirewallManager.rules[@carto_user1.username]).to be_nil
            end
          end
        end
    end

    it 'creates ips with api_key authentication' do
      ips = ['100.20.30.40']
      params = {
        ips: ips,
        api_key: @carto_user1.api_key
      }
      with_feature_flag @carto_user1, 'dbdirect', true do
        Cartodb.with_config dbdirect: @config do
          put_json(dbdirect_ip_url, params) do |response|
            expect(response.status).to eq(201)
            expect(response.body[:ips]).to eq ips
            expect(@carto_user1.reload.dbdirect_effective_ips).to eq ips
            expect(TestFirewallManager.rules[@carto_user1.username]).to eq ips
            expect(TestFirewallManager.config).to eq 'the-config'
          end
        end
      end
    end

    it 'creates ips with login authentication' do
      ips = ['100.20.30.40']
      params = {
        ips: ips
      }
      with_feature_flag @carto_user1, 'dbdirect', true do
        Cartodb.with_config dbdirect: @config do
          login_as(@carto_user1, scope: @carto_user1.username)
          put_json(dbdirect_ip_url, params) do |response|
            expect(response.status).to eq(201)
            expect(response.body[:ips]).to eq ips
            expect(@carto_user1.reload.dbdirect_effective_ips).to eq ips
            expect(TestFirewallManager.rules[@carto_user1.username]).to eq ips
            expect(TestFirewallManager.config).to eq 'the-config'
          end
        end
      end
    end

    it 'retains only latest ips assigned' do
      ips1 = ['100.20.30.40', '200.20.30.40/24']
      ips2 = ['11.21.31.41']
      with_feature_flag @carto_user1, 'dbdirect', true do
        Cartodb.with_config dbdirect: @config do
          params = {
            ips: ips1,
            api_key: @carto_user1.api_key
          }
          put_json(dbdirect_ip_url, params) do |response|
            expect(response.status).to eq(201)
            expect(response.body[:ips]).to eq ips1
            expect(@carto_user1.reload.dbdirect_effective_ips).to eq ips1
            expect(TestFirewallManager.rules[@carto_user1.username]).to eq ips1
            expect(TestFirewallManager.config).to eq 'the-config'
          end

          params = {
            ips: ips2,
            api_key: @carto_user1.api_key
          }
          put_json(dbdirect_ip_url, params) do |response|
            expect(response.status).to eq(201)
            expect(response.body[:ips]).to eq ips2
            expect(@carto_user1.reload.dbdirect_effective_ips).to eq ips2
            expect(TestFirewallManager.rules[@carto_user1.username]).to eq ips2
            expect(TestFirewallManager.config).to eq 'the-config'
          end
        end
      end
    end

    it 'rejects invalid IPs' do
      invalid_ips = [
        ['0.0.0.0'], ['10.20.30.40'], ['127.0.0.1'], ['192.168.1.1'],
        ['120.120.120.120/20'], ['100.100.100.300'], ['not-an-ip'],
        [11223344],
        '100.20.30.40'
      ]
      invalid_ips.each do |ips|
        params = {
          ips: ips,
          api_key: @carto_user1.api_key
        }

        with_feature_flag @carto_user1, 'dbdirect', true do
          Cartodb.with_config dbdirect: @config do
            put_json(dbdirect_ip_url, params) do |response|
              expect(response.status).to eq(422)
              expect(response.body[:errors]).not_to be_nil
              expect(response.body[:errors][:ips]).not_to be_nil
              expect(@carto_user1.reload.dbdirect_effective_ips).to be_empty
              expect(TestFirewallManager.rules[@carto_user1.username]).to be_nil
            end
          end
        end

      end
    end

    it 'IP changes affect all the organization members' do
      ips = ['100.20.30.40']
      params = {
        ips: ips,
        api_key: @org_user.api_key
      }
      with_host "#{@org_user.username}.localhost.lan" do
        with_feature_flag @org_user, 'dbdirect', true do
          Cartodb.with_config dbdirect: @config do
            put_json dbdirect_ip_url(params.merge(host: host)) do |response|
              expect(response.status).to eq(201)
              expect(response.body[:ips]).to eq ips
              expect(@org_user.reload.dbdirect_effective_ips).to eq ips
              expect(@org_owner.reload.dbdirect_effective_ips).to eq ips
              expect(TestFirewallManager.rules[@organization.name]).to eq ips
              expect(TestFirewallManager.rules[@org_user.username]).to be_nil
              expect(TestFirewallManager.rules[@org_owner.username]).to be_nil
              expect(TestFirewallManager.config).to eq 'the-config'
            end
          end
        end
      end
    end

    it 'returns error response if firewall service fails' do
      Carto::DbdirectIp.stubs(:firewall_manager_class).returns(TestErrorFirewallManager)
      ips = ['100.20.30.40']
      params = {
        ips: ips
      }
      with_feature_flag @carto_user1, 'dbdirect', true do
        Cartodb.with_config dbdirect: @config do
          login_as(@carto_user1, scope: @carto_user1.username)
          put_json(dbdirect_ip_url, params) do |response|
            expect(response.status).to eq(500)
            expect(response.body[:errors]).to match(/FIREWALL ERROR/)
            expect(@carto_user1.reload.dbdirect_effective_ips).to be_empty
            expect(TestFirewallManager.rules[@carto_user1.username]).to be_nil
          end
        end
      end
    end
  end

  describe '#destroy' do
    before(:each) do
      @params = { api_key: @carto_user1.api_key }
      @existing_ips = ['100.20.30.40']
      Carto::DbdirectIp.stubs(:firewall_manager_class).returns(TestFirewallManager)
      @carto_user1.dbdirect_effective_ips = @existing_ips
      TestFirewallManager.rules[@carto_user1.username] = @existing_ips
    end

    after(:each) do
      Carto::DbdirectIp.delete_all
      TestFirewallManager.rules.clear
      TestFirewallManager.config = nil
    end

    it 'needs authentication for ips deletion' do
      params = {}
      Cartodb.with_config dbdirect: @config do
        delete_json dbdirect_ip_url(params) do |response|
          expect(response.status).to eq(401)
          expect(@carto_user1.reload.dbdirect_effective_ips).to eq @existing_ips
          expect(TestFirewallManager.rules[@carto_user1.username]).to eq @existing_ips
        end
      end
    end

    it 'needs the feature flag for ips deletion' do
      params = {
        api_key: @carto_user1.api_key
      }
      with_feature_flag @carto_user1, 'dbdirect', false do
        Cartodb.with_config dbdirect: @config do
          delete_json dbdirect_ip_url(params) do |response|
            expect(response.status).to eq(403)
            expect(@carto_user1.reload.dbdirect_effective_ips).to eq @existing_ips
            expect(TestFirewallManager.rules[@carto_user1.username]).to eq @existing_ips
          end
        end
      end
    end

    it 'deletes ips with api_key authentication' do
      params = {
        api_key: @carto_user1.api_key
      }
      with_feature_flag @carto_user1, 'dbdirect', true do
        Cartodb.with_config dbdirect: @config do
          delete_json dbdirect_ip_url(params) do |response|
            expect(response.status).to eq(204)
            expect(@carto_user1.reload.dbdirect_effective_ips).to be_empty
            expect(TestFirewallManager.rules[@carto_user1.username]).to be_empty
            expect(TestFirewallManager.config).to eq 'the-config'
          end
        end
      end
    end

    it 'deletes ips with login authentication' do
      params = {
      }
      with_feature_flag @carto_user1, 'dbdirect', true do
        Cartodb.with_config dbdirect: @config do
          login_as(@carto_user1, scope: @carto_user1.username)
          delete_json dbdirect_ip_url(params) do |response|
            expect(response.status).to eq(204)
            expect(@carto_user1.reload.dbdirect_effective_ips).to be_empty
            expect(TestFirewallManager.rules[@carto_user1.username]).to be_empty
            expect(TestFirewallManager.config).to eq 'the-config'
          end
        end
      end
    end

    it 'returns error response if firewall service fails' do
      Carto::DbdirectIp.stubs(:firewall_manager_class).returns(TestErrorFirewallManager)
      params = {
      }
      with_feature_flag @carto_user1, 'dbdirect', true do
        Cartodb.with_config dbdirect: @config do
          login_as(@carto_user1, scope: @carto_user1.username)
          delete_json dbdirect_ip_url(params) do |response|
            expect(response.status).to eq(500)
            expect(response.body[:errors]).to match(/FIREWALL ERROR/)
            expect(@carto_user1.reload.dbdirect_effective_ips).to eq @existing_ips
            expect(TestFirewallManager.rules[@carto_user1.username]).to eq @existing_ips
          end
        end
      end
    end
  end

  describe '#show' do
    before(:each) do
      @ips = ['100.20.30.40']
      Carto::DbdirectIp.stubs(:firewall_manager_class).returns(TestFirewallManager)
      @carto_user1.dbdirect_effective_ips = @ips
    end

    after(:each) do
      Carto::DbdirectCertificate.delete_all
      TestFirewallManager.rules.clear
      TestFirewallManager.config = nil
    end

    it 'needs authentication for showing ips' do
      params = {
      }
      Cartodb.with_config dbdirect: @config do
        get_json dbdirect_ip_url(params) do |response|
          expect(response.status).to eq(401)
        end
      end
    end

    it 'needs the feature flag for showing ips' do
      params = {
        api_key: @carto_user1.api_key
      }
      with_feature_flag @carto_user1, 'dbdirect', false do
        Cartodb.with_config dbdirect: @config do
          get_json dbdirect_ip_url(params) do |response|
            expect(response.status).to eq(403)
          end
        end
      end
    end

    it 'shows ips with api key authentication' do
      params = {
        api_key: @carto_user1.api_key
      }
      with_feature_flag @carto_user1, 'dbdirect', true do
        Cartodb.with_config dbdirect: @config do
          get_json dbdirect_ip_url(params) do |response|
            expect(response.status).to eq(200)
            expect(response.body[:ips]).to eq @ips
          end
        end
      end
    end

    it 'shows ips with login authentication' do
      params = {
      }
      with_feature_flag @carto_user1, 'dbdirect', true do
        login_as(@carto_user1, scope: @carto_user1.username)
        Cartodb.with_config dbdirect: @config do
          get_json dbdirect_ip_url(params) do |response|
            expect(response.status).to eq(200)
            expect(response.body[:ips]).to eq @ips
          end
        end
      end
    end

    it 'returns empty ips array when not configured' do
      params = {
        api_key: @carto_user1.api_key
      }
      @carto_user1.reload.dbdirect_effective_ips = nil
      with_feature_flag @carto_user1, 'dbdirect', true do
        Cartodb.with_config dbdirect: @config do
          get_json dbdirect_ip_url(params) do |response|
            expect(response.status).to eq(200)
            expect(response.body[:ips]).to eq []
          end
        end
      end
    end
  end
end
