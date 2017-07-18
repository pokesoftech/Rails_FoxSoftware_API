module DeviseTokenAuth
  class RegistrationsController < DeviseTokenAuth::ApplicationController
    before_filter :set_user_by_token, only: [:destroy, :update]
    before_filter :validate_sign_up_params, only: :create
    before_filter :validate_account_update_params, only: :update
    skip_after_filter :update_auth_header, only: [:create, :destroy]

    # :nocov:
    swagger_controller :registrations, 'User email registration'

    def self.generic_user_details(api)
      api.param :form, :first_name, :string, :required, 'First Name'
      api.param :form, :last_name, :string, :required, 'Last Name'
      api.param :form, :email, :string, :required, 'Email'
      api.param :form, :password, :string, :required, 'Password'
      api.param :form, :password_confirmation, :string, :required, 'Password confirmation'
      api.param :form, :about, :string, :optional, 'About me'
      api.param :form, :mc_num, :string, :optional, 'MC number'
    end

    swagger_api :create do |api|
      summary 'CREATE user with email'
      notes 'When invited by user(url with query string <strong>invitation=</strong>, we will find and assign all shipment invitations by email, so later you can load them from <strong>my_invitations</strong> query'
      Api::V1::DeviseTokenAuth::RegistrationsController.generic_user_details(api)
      param :form, :user_type, :string, :required, "User type, 'carrier' or 'shipper'"
      param :form, :invitation, :string, :optional, 'Invitation code, pass from query string if available. IF invitation present and valid then new user will be assigned with carrier role regardless of user_type field'
      # param :form, :provider, :string, :required, "Provider, one of: (email,facebook,google_oauth2,linkedin)", {defaultValue: 'email'}
      response 'not_valid'
      response 'ok', 'Success', :User
    end
    # :nocov:
    def create

      @resource            = resource_class.new(sign_up_params)
      @resource.provider   = 'email'

      # honor devise configuration for case_insensitive_keys
      if resource_class.case_insensitive_keys.include?(:email)
        @resource.email = sign_up_params[:email].try :downcase
      else
        @resource.email = sign_up_params[:email]
      end

      ### Dont use it. use our - set in devise_token_auth initializer
      # give redirect value from params priority
      # redirect_url = params[:confirm_success_url]
      # fall back to default value if provided
      redirect_url = DeviseTokenAuth.default_confirm_success_url
      # success redirect url is required
      # if resource_class.devise_modules.include?(:confirmable) && !redirect_url
      #   return render json: {
      #     status: 'error',
      #     data:   @resource.as_json,
      #     errors: [I18n.t("devise_token_auth.registrations.missing_confirm_success_url")]
      #   }, status: 403
      # end
      # if whitelist is set, validate redirect_url against whitelist
      # if DeviseTokenAuth.redirect_whitelist
      #   unless DeviseTokenAuth.redirect_whitelist.include?(redirect_url)
      #     return render json: {
      #       status: 'error',
      #       data:   @resource.as_json,
      #       errors: [I18n.t("devise_token_auth.registrations.redirect_url_not_allowed", redirect_url: redirect_url)]
      #     }, status: 403
      #   end
      # end

      begin
        # override email confirmation, must be sent manually from ctrl
        resource_class.skip_callback("create", :after, :send_on_create_confirmation_instructions)
        invitation = params[:invitation]
        invitation = Shipment.active.where(secret_id: invitation).first if invitation
        @resource.skip_confirmation! if invitation
        if @resource.save
          if invitation
            @resource.add_role :carrier
            # Also user has after_create filter which assign ship_invitations automatically
          else
            @resource.assign_role_by_param(params[:user_type])
          end

          yield @resource if block_given?

          unless @resource.confirmed?
            # user will require email authentication
            @resource.send_confirmation_instructions({
              client_config: params[:config_name],
              redirect_url: redirect_url
            })
          else
            # email auth has been bypassed, authenticate user
            @client_id = SecureRandom.urlsafe_base64(nil, false)
            @token     = SecureRandom.urlsafe_base64(nil, false)

            @resource.tokens[@client_id] = {
              token: BCrypt::Password.create(@token),
              expiry: (Time.now + DeviseTokenAuth.token_lifespan).to_i
            }

            @resource.save!

            update_auth_header
          end

          render_json @resource
          # render json: {
          #   status: 'success',
          #   data:   @resource.as_json
          # }
        else
          clean_up_passwords @resource
          render json: {
            status: 'error',
            data:   @resource.as_json,
            errors: @resource.errors.to_hash.merge(full_messages: @resource.errors.full_messages)
          }, status: 403
        end
      rescue ActiveRecord::RecordNotUnique
        clean_up_passwords @resource
        render json: {
          status: 'error',
          data:   @resource.as_json,
          errors: [I18n.t("devise_token_auth.registrations.email_already_exists", email: @resource.email)]
        }, status: 403
      end
    end

    # :nocov:
    swagger_api :update do |api|
      summary 'UPDATE user details'
      Api::V1::DeviseTokenAuth::RegistrationsController.generic_user_details(api)
      param :form, :current_password, :string, :optional, 'Current password, use to change password'
      response 'not_valid', "{'message': [ArrayOfErrors]}"
      response 'ok'
    end
    # :nocov:
    def update
      if @resource
        if @resource.send(resource_update_method, account_update_params)
          yield @resource if block_given?
          render_ok
          # render json: {
          #   status: 'ok',
          #   data:   @resource.as_json
          # }
        else
          render_error 'not_valid', 403, @resource.errors.to_hash.merge(full_messages: @resource.errors.full_messages)
        end
      else
        render_error 'not_found', 404
      end
    end

    # def destroy
    #   if @resource
    #     @resource.destroy
    #     yield @resource if block_given?
    #
    #     render json: {
    #       status: 'success',
    #       message: I18n.t("devise_token_auth.registrations.account_with_uid_destroyed", uid: @resource.uid)
    #     }
    #   else
    #     render json: {
    #       status: 'error',
    #       errors: [I18n.t("devise_token_auth.registrations.account_to_destroy_not_found")]
    #     }, status: 404
    #   end
    # end

    def sign_up_params
      params.permit(devise_parameter_sanitizer.for(:sign_up))
    end

    def account_update_params
      params.permit(devise_parameter_sanitizer.for(:account_update))
    end

    private

    def resource_update_method
      if DeviseTokenAuth.check_current_password_before_update == :attributes
        "update_with_password"
      elsif DeviseTokenAuth.check_current_password_before_update == :password and account_update_params.has_key?(:password)
        "update_with_password"
      elsif account_update_params.has_key?(:current_password)
        "update_with_password"
      else
        "update_attributes"
      end
    end

    def validate_sign_up_params
      validate_post_data sign_up_params, I18n.t("errors.validate_sign_up_params")
    end

    def validate_account_update_params
      validate_post_data account_update_params, I18n.t("errors.validate_account_update_params")
    end

    def validate_post_data which, message
      render json: {
         error: 'not_valid',
         message: [message]
      }, status: :unprocessable_entity if which.empty?
    end
  end
end