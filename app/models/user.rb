# coding: utf-8
class User < ActiveRecord::Base
  include User::OmniauthHandler
  has_notifications
  acts_as_copy_target
  # Include default devise modules. Others available are:
  # :token_authenticatable, :encryptable, :confirmable, :lockable, :timeoutable and :omniauthable
  # :validatable
  devise          :database_authenticatable,
                  :registerable,
                  :recoverable,
                  :rememberable,
                  :trackable,
                  :omniauthable

  delegate  :display_name, :display_image, :short_name, :display_image_html,
    :medium_name, :display_credits, :display_total_of_contributions, :contributions_text,
    :twitter_link, :gravatar_url, :display_bank_account, :display_bank_account_owner,
    :larger_display_image, :projects_count, to: :decorator

  attr_accessible :email, :password, :password_confirmation, :remember_me,
                  :name, :image_url, :uploaded_image, :bio, :newsletter, :full_name,
                  :address_street, :address_number, :address_complement, :address_city,
                  :address_neighbourhood, :address_state, :address_zip_code, :phone_number,
                  :cpf, :state_inscription, :locale, :twitter, :facebook_link, :other_link,
                  :moip_login, :deactivated_at, :reactivate_token, :bank_account_attributes,
                  :access_type, :responsible_name, :responsible_cpf, :mobile_phone, :gender,
                  :staffs, :job_title, :birth_date, :admin, :original_doc1_url,
                  :original_doc2_url, :original_doc3_url, :original_doc4_url,
                  :original_doc5_url, :original_doc6_url, :original_doc7_url,
                  :original_doc8_url, :original_doc9_url, :original_doc10_url,
                  :original_doc11_url, :original_doc12_url, :original_doc13_url

  enum access_type: [:individual, :legal_entity]
  enum gender:      [:male, :female]

  STAFFS = {
    team:             0,
    financial_board:  1,
    technical_board:  2,
    advice_board:     3
  }

  mount_uploader :uploaded_image, UserUploader

  validates :bio, length: { maximum: 140 }
  validates :access_type, presence: true
  validates :email, presence: true
  validates :email,
              allow_blank: true,
              uniqueness: true,
              format: { with: Devise.email_regexp },
              if: :email_changed?
  validates :password,
              presence: { if: :password_required? },
              confirmation: { if: :password_confirmation_required? },
              length: { within: Devise.password_length },
              allow_blank: true

  belongs_to :channel
  belongs_to :country
  has_one    :user_total
  has_one    :bank_account
  has_many   :credit_cards
  has_many   :contributions
  has_many   :authorizations
  has_many   :channel_posts
  has_many   :channels_subscribers
  has_many   :projects
  has_many   :unsubscribes
  has_many   :project_posts
  has_many   :contributed_projects, -> { where(contributions: { state: 'confirmed' } ).uniq } ,through: :contributions, source: :project
  has_many   :category_followers
  has_many   :categories, through: :category_followers
  has_and_belongs_to_many :recommended_projects, join_table: :recommendations, class_name: 'Project'
  has_and_belongs_to_many :subscriptions, join_table: :channels_subscribers, class_name: 'Channel'

  accepts_nested_attributes_for :unsubscribes, allow_destroy: true rescue puts "No association found for name 'unsubscribes'. Has it been defined yet?"
  accepts_nested_attributes_for :bank_account, allow_destroy: true

  scope :active,                      -> { where(deactivated_at: nil) }
  scope :staff,                       -> { where(staff_members_query) }
  scope :has_credits,                 -> { joins(:user_total).where('credits > ?', 0) }
  scope :only_organizations,          -> { where(access_type: User.access_types[:legal_entity]) }
  scope :by_email,                    -> (email) { where('email ~* ?', email) }
  scope :order_by,                    -> (sort_field) { order(sort_field) }
  scope :by_name,                     -> (name) { where('users.name ~* ?', name) }
  scope :by_id,                       -> (id) { where(id: id) }
  scope :by_contribution_key,         -> (key) { joins(:contributions).merge(Contribution.by_key(key)) }
  scope :subscribed_to_posts,         -> { where.not(id: Unsubscribe.where(project_id: nil).select(:user_id)) }
  scope :who_contributed_project,     -> (project_id) { includes(:contributions).merge(Contribution.confirmed_state).where(contributions: { project_id: project_id } ) }
  scope :with_visible_projects,       -> { joins(:projects).where.not(projects: { state: ['draft', 'rejected', 'deleted', 'in_analysis'] } ) }
  scope :subscribed_to_project, -> (project_id) do
    user_ids = Unsubscribe.where(project_id: project_id).select(:user_id)

    who_contributed_project(project_id).where.not(id: user_ids)
  end
  scope :by_payer_email, ->(email) { joins(:contributions => :payment_notifications).where('extra_data ~* ?', email) }
  scope :to_send_category_notification, -> (category_id) do
    user_ids = CategoryNotification.where(
                template_name: 'categorized_projects_of_the_week',
                category_id: category_id
                ).where('created_at >= ?', Time.current-7.days).select(:user_id)

    where.not(id: user_ids)
  end
  scope :already_used_credits, -> do
    user_ids = Contribution.credits.confirmed_state.select(:user_id)

    has_credits.where(id: user_ids)
  end
  scope :has_not_used_credits_last_month, -> do
    user_ids = Contribution.credits.confirmed_state.where("created_at < ?", Time.now-1.month).select(:user_id)

    has_credits.where(id: user_ids)
  end

  def self.find_active!(id)
    self.active.where(id: id).first!
  end

  def following_this_category?(category_id)
    category_followers.pluck(:category_id).include?(category_id)
  end

  def send_credits_notification
    self.notify(:credits_warning)
  end

  def change_locale(language)
    if locale != language
      self.update_attributes locale: language
    end
  end

  def active_for_authentication?
    super && deactivated_at.nil?
  end

  def reactivate
    self.update_attributes deactivated_at: nil, reactivate_token: nil
  end

  def deactivate
    self.notify(:user_deactivate)
    self.update_attributes deactivated_at: Time.now, reactivate_token: Devise.friendly_token
    self.contributions.update_all(anonymous: true)
  end

  def made_any_contribution_for_this_project?(project_id)
    contributions.available_to_count.where(project_id: project_id).present?
  end

  def decorator
    @decorator ||= UserDecorator.new(self)
  end

  def credits
    user_total.try(:credits).to_f
  end

  def projects_in_reminder
    p = Array.new
    reminder_jobs = Sidekiq::ScheduledSet.new.select do |job|
      job['class'] == 'ReminderProjectWorker' && job.args[0] == self.id
    end
    reminder_jobs.each do |job|
      p << Project.find(job.args[1])
    end
    return p
  end

  def total_contributed_projects
    user_total.try(:total_contributed_projects).to_i
  end

  def has_no_confirmed_contribution_to_project(project_id)
    contributions.where(project_id: project_id).with_states(['confirmed','waiting_confirmation']).empty?
  end

  def created_today?
    self.created_at.to_date == Date.today && self.sign_in_count <= 1
  end

  def to_analytics_json
    {
      id: self.id,
      email: self.email,
      total_contributed_projects: self.total_contributed_projects,
      total_created_projects: self.projects.count,
      created_at: self.created_at,
      last_sign_in_at: self.last_sign_in_at,
      sign_in_count: self.sign_in_count,
      created_today: self.created_today?
    }.to_json
  end

  def to_param
    return "#{self.id}" unless self.display_name
    "#{self.id}-#{self.display_name.parameterize}"
  end

  def posts_subscription
    unsubscribes.posts_unsubscribe(nil)
  end

  def project_unsubscribes
    contributed_projects.map do |p|
      unsubscribes.posts_unsubscribe(p.id)
    end
  end

  def project_owner?
    projects.present?
  end

  def fix_twitter_user
    self.twitter.gsub!(/@/, '') if self.twitter
  end

  def fix_facebook_link
    if self.facebook_link.present?
      self.facebook_link = ('http://' + self.facebook_link) unless self.facebook_link[/^https?:\/\//]
    end
  end

  def password_required?
    !persisted? || !password.nil? || !password_confirmation.nil?
  end

  def password_confirmation_required?
    !new_record?
  end

  def has_valid_contribution_for_project?(project_id)
    contributions.with_state(['confirmed', 'requested_refund', 'waiting_confirmation']).where(project_id: project_id).present?
  end

  def generate_reset_password_token
    raw, enc = Devise.token_generator.generate(self.class, :reset_password_token)
    self.reset_password_token   = enc
    self.reset_password_sent_at = Time.now.utc
    self.save(validate: false)
    raw
  end

  def self.staff_descriptions
    STAFFS.keys.map { |description| User.human_attribute_name("staff.#{description}") }
  end

  def approved?
    access_type == 'individual' || (approved_at && approved_at > Time.now - 1.year)
  end

  def pending_documents?
    access_type == 'individual' && !(original_doc12_url? && original_doc13_url?)
  end

  def fix_name_encoding
    n = name
    n.gsub! 'Ã‡', 'Ç'
    n.gsub! 'Ã€', 'À'
    n.gsub! 'Ãƒ', 'Ã'
    n.gsub! 'Ã‰', 'É'
    n.gsub! 'ÃŠ', 'Ê'
    n.gsub! 'Ã§', 'ç'
    n.gsub! 'Ã©', 'é'
    n.gsub! 'Ã¡', 'á'
    n.gsub! 'Ã¢', 'â'
    n.gsub! 'Ã£', 'ã'
    n.gsub! 'Ã§Ã£', 'çã'
    self.name = n
    self.save
  end

  def documents_list
    if (access_type == 'individual')
      [:original_doc12_url, :original_doc13_url]
    else
      [
        :original_doc1_url, :original_doc2_url, :original_doc3_url,
        :original_doc4_url, :original_doc5_url, :original_doc6_url,
        :original_doc7_url, :original_doc8_url, :original_doc9_url,
        :original_doc10_url, :original_doc11_url, :original_doc12_url,
        :original_doc13_url
      ]
    end
  end

  def self.staff_members_query
    STAFFS.values.map { |value| "staffs @> ARRAY[#{value}]" }.join(' OR ')
  end

  def failed_contributed_projects
    contributed_projects.where(state: 'failed')
  end
end
