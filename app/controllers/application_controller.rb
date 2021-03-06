class ApplicationController < ActionController::Base
  # Prevent CSRF attacks by raising an exception.
  # For APIs, you may want to use :null_session instead.
  protect_from_forgery with: :exception
  helper_method :current_user

  # for actions that don't require_authentication or require_admin,
  # we still need to set_current_user_to_api_user so that users can
  # optionally have authenticated access to public routes.
  # for example, /auctions/:id/bids will unveil bidder info about
  # the authenticated user. but the page also works fine sans authentication.
  before_action :set_current_user_to_api_user!, if: proc { api_request? }

  def current_user
    @current_user ||= User.where(id: session[:user_id]).first
  end

  def require_authentication
    if html_request?
      redirect_if_not_logged_in!
    elsif api_request?
      set_current_user_to_api_user!(raise_errors: true)
    end
  end

  def require_admin
    if html_request?
      # if the request is via the web UI,
      # we need 'and return' to ensure the redirect happens.
      require_authentication and return
    elsif api_request?
      # otherwise, if it's an API request, we don't need to redirect.
      require_authentication
    end
    is_admin = Admins.verify?(github_id)
    fail UnauthorizedError::MustBeAdmin unless is_admin

    is_admin
  end

  rescue_from 'UnauthorizedError::MustBeAdmin' do |error|
    message = error.message || "Unauthorized"
    handle_error(message)
  end

  rescue_from UnauthorizedError do |error|
    message = error.message || "Unauthorized"
    handle_error(message)
  end

  rescue_from 'UnauthorizedError::UserNotFound' do |error|
    message = error.message || "User not found"
    handle_error(message)
  end

  def html_request?
    request.format.symbol == :html
  end

  def api_request?
    [:json].include? request.format.symbol
  end

  def api_key
    request.headers['HTTP_API_KEY']
  end

  def github_id_from_api_key(api_key)
    return nil if api_key.nil?

    client = Octokit::Client.new(access_token: api_key)
    client.user.id
  rescue Octokit::Unauthorized => e
    raise UnauthorizedError::GitHubAuthenticationError, "Error authenticating via GitHub: #{e.message}"
  end

  def redirect_if_not_logged_in!
    should_redirect = !current_user
    redirect_to '/login' if should_redirect
    should_redirect
  end

  # rubocop:disable Style/AccessorMethodName
  def set_current_user_to_api_user!(raise_errors: false)
    user = User.where(github_id: github_id).first

    fail UnauthorizedError::UserNotFound if user.nil? && raise_errors
    @current_user = user
  end
  # rubocop:enable Style/AccessorMethodName

  def github_id
    if html_request? && current_user
      current_user.github_id
    elsif api_request?
      begin
        return github_id_from_api_key(api_key)
      rescue UnauthorizedError::GitHubAuthenticationError
        return nil
      end
    end
    # returns nil otherwise
  end

  private

  def handle_error(message)
    if html_request?
      flash[:error] = message
      redirect_to '/'
    elsif api_request?
      render json: {error: message}, status: 404
    end
  end
end
