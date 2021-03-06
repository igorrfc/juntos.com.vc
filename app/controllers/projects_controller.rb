# coding: utf-8
include ActionView::Helpers::NumberHelper

class ProjectsController < ApplicationController
  after_filter :verify_authorized, except: %i[total index video video_embed embed embed_panel about_mobile supported_by_channel permalink_valid? generate_subscriptions_report]
  inherit_resources
  has_scope :pg_search, :by_category_id, :near_of
  has_scope :recent, :expiring, :failed, :successful, :in_funding, :recommended, :not_expired, type: :boolean

  respond_to :html
  respond_to :json, only: [:index, :show, :update]

  def index
    index! do |format|
      format.html do
        @projects = apply_scopes(visible_projects)

        if request.xhr?
          @projects = @projects.visible.order_status
                      .most_recent_first
                      .includes(:project_total, :user, :category)
                      .page(params[:page])
                      .per(6)

          return render partial: 'project', collection: @projects, layout: false
        else
          @index_scope = Project::IndexScope.new(@projects, current_user)
        end
      end
    end
  end

  def new
    @project = Project.new user: current_user, new_record: true
    authorize @project
    @title = t('projects.new.title')
    8.times { @project.project_images.build }
    3.times { @project.project_partners.build }
    @project.rewards.build
    @project.subgoals.build
  end

  def create
    options = {user: current_user}
    options.merge!(channels: [channel]) if channel

    @project = Project.new(user: current_user, new_record: true)
    authorize @project
    response = Project::Create.new(current_user, project_params.merge(options))
    @project = response.project

    if response.process
      session[:new_project] = true
      redirect_to project_by_slug_path(@project.permalink, anchor: 'basics')
    else
      flash[:alert] = response.project.errors.full_messages.to_sentence
      render :new
    end
  end

  def destroy
    authorize resource
    destroy!
  end

  def total
    summary = Summary.first
    if summary
      two_hours_ago = DateTime.now - (2/24.0)
      step = 1
      if summary.updated_at < two_hours_ago
        step = 2
        statistics = Statistics.first
        projects = Project.visible.select{|p| p.progress >= 100 || p.state == 'successful'}.count
        summary.total_projects = projects
        summary.contributions = statistics.total_contributions
        summary.total = statistics.total_contributed
        summary.save
      end
    else
      step = 3
      statistics = Statistics.first
      projects = Project.visible.select{|p| p.progress >= 100 || p.state == 'successful'}.count
      summary = Summary.new(total_projects: projects, contributions: statistics.total_contributions, total: statistics.total_contributed)
    end

    contributed = number_with_precision(summary.total, precision: 0)
    total = summary.contributions
    projects = summary.total_projects
    render json: [:projects => projects, :contributed => contributed, :total => total, :step => step]
  end

  def send_to_analysis
    authorize resource

    if resource.send_to_analysis
      resource.update_attribute(:referal_link, referal_link) if referal_link.present?

      flash[:notice] = t('projects.send_to_analysis')
      redirect_to project_by_slug_path(@project.permalink)
    else
      flash[:alert] = resource.errors.full_messages.to_sentence
      redirect_to project_by_slug_path(@project.reload.permalink,
                                       anchor: 'dashboard_project')
    end
  end

  def update
    authorize resource
    @project_update = Project::Update.new(current_user, project_params, resource)

    if @project_update.process
      @project = @project_update.project
      flash[:notice] = t('project.update.success')
    else
      flash[:alert] = @project_update.project.errors.full_messages.to_sentence
    end

    redirect_to project_by_slug_path(@project.reload.permalink, anchor: (params[:anchor] || 'dashboard_project') )
  end

  def show
    @title = resource.name
    authorize @project
    fb_admins_add(resource.user.facebook_id) if resource.user.facebook_id
    @channel = resource.channels.first
    @posts_count = resource.posts.count(:all)
    @post = resource.posts.where(id: params[:project_post_id]).first if params[:project_post_id].present?
    @pending_contributions = @project.contributions.with_state(:waiting_confirmation)
    @project_documentation = ProjectDocumentationViewObject.new(
      banks: Bank.order(:code).to_collection,
      project: @project
    )

    if @project.recurring?
      @plans = Plan.active
      @last_subscription_report = @project.subscription_reports.try(:last)
      @supporters = User.with_paid_subscriptions_for_project(@project.id)
    else
      @contributions = @project.contributions.available_to_count
    end
  end

  def video
    project = Project.new(video_url: params[:url])
    render json: project.video.to_json
  rescue VideoInfo::UrlError
    render json: nil
  end

  %w(embed video_embed).each do |method_name|
    define_method method_name do
      @title = resource.name
      render layout: 'embed'
    end
  end

  def about_mobile
    resource
  end

  def embed_panel
    @title = resource.name
    render layout: false
  end

  def supported_by_channel
    render json: channel.projects
  end

  def permalink_valid?
    @projects = Project.by_permalink(params[:permalink])

    permalink_available = @projects.empty? || @projects.pluck(:id).include?(params[:project_id].to_i)

    render json: { available_permalink: permalink_available }
  end

  def generate_subscriptions_report
    if policy(Project.find(params[:project_id])).update?
      Reports::SubscriptionWorker.perform_async(params[:project_id])

      flash[:notice] = flash[:notice] = t('projects.recurring.report_waiting_to_be_ready')
      redirect_to :back
    else
      head 401
    end
  end

  protected

  def permitted_params
    p = params.permit(policy(resource).permitted_attributes)
    if params[:anchor] == 'posts'
      p[:project][:posts_attributes]['0'].merge!({user: current_user})
    end
    p
  end

  def project_params
    permitted_params[:project]
  end

  def resource
    @project ||= (params[:permalink].present? ? Project.by_permalink_and_available(params[:permalink]).first! : Project.find(params[:id])).decorate
  end

  def use_catarse_boostrap
    ["new", "create", "show", "about_mobile"].include?(action_name) ? 'juntos_bootstrap' : 'application'
  end

  private

  def visible_projects
    @visible_projects ||=
      if current_user.present? && current_user.admin?
        Project.without_recurring_and_pepsico_channel
      else
        Project.with_visible_channel_and_without_channel.without_recurring_and_pepsico_channel
      end
  end
end
