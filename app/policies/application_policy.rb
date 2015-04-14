class ApplicationPolicy
  attr_reader :user, :record, :channel

  def initialize(user, record, channel = nil)
    @user = user
    @record = record
    @channel = channel
  end

  def index?
    true
  end

  def show?
    true
  end

  def create?
    is_admin?
  end

  def new?
    create?
  end

  def update?
    is_admin?
  end

  def edit?
    update?
  end

  def destroy?
    is_admin?
  end

  def scope
    Pundit.policy_scope!(user, record.class)
  end

  def permitted_for?(field, operation)
    permitted?(field) && send("#{operation}?")
  end

  def permitted?(field)
    permitted_attributes.values.first.include? field
  end

  protected
  def is_admin?
    user.try(:admin?) || false
  end

  def done_by_owner_or_admin?
    is_owned_by?(user) || is_admin? || is_project_channel_admin?
  end

  def is_owned_by?(user)
    user.present? && record.user == user
  end

  def is_project_channel_admin?
    user.present? && record.channels.try(:first).try(:users).try(:include?, user)
  end

  def is_channel_admin?
    user.try(:channel) == @channel && @channel.present?
  end
end

