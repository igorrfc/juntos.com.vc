# coding: utf-8

require 'rails_helper'

RSpec.describe "Users", type: :feature do
  before do
    OauthProvider.create! name: 'facebook', key: 'dummy_key', secret: 'dummy_secret'
  end

  describe "redirect to the last page after login" do
    let!(:project) { create(:project) }
    before do
      visit project_by_slug_path(permalink: project.permalink)
      login
    end

    it { expect(current_path).to eq(project_by_slug_path(permalink: project.permalink)) }
  end

  describe "the notification tab" do
    before do
      login
      @project = create(:contribution, user: current_user).project
      visit user_path(current_user, locale: :pt)
      click_link 'unsubscribes_link'
    end

    xit "should show unsubscribe from all updates" do
      updates_unsubscribe = all("#user_unsubscribes_attributes_0_subscribed")
      expect(updates_unsubscribe.size).to eq(1)
    end
  end
end
