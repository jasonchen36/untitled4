require 'paypal-sdk-adaptivepayments'
require 'uri'

class TransactionsController < ApplicationController

  TransactionStore = TransactionService::Store::Transaction

  protect_from_forgery :except => [:create] #Otherwise the request from PayPal wouldn't make it to the controller
  before_filter only: [:show] do |controller|
    controller.ensure_logged_in t("layouts.notifications.you_must_log_in_to_view_your_inbox")
  end

  before_filter do |controller|
    controller.ensure_logged_in t("layouts.notifications.you_must_log_in_to_do_a_transaction")
  end

  MessageForm = Form::Message
  TransactionForm = EntityUtils.define_builder(
    [:listing_id, :fixnum, :to_integer, :mandatory],
    [:message, :string],
    [:name, :string],
    [:city, :string],
    [:street, :string],
    [:street2, :string],
    [:phone, :string],
    [:province, :string],
    [:postal, :string],
    [:country, :string],
    [:quantity, :fixnum, :to_integer, default: 1],
    [:start_on, transform_with: ->(v) { Maybe(v).map { |d| TransactionViewUtils.parse_booking_date(d) }.or_else(nil) } ],
    [:end_on, transform_with: ->(v) { Maybe(v).map { |d| TransactionViewUtils.parse_booking_date(d) }.or_else(nil) } ]
  )

  def thank_you
    render "transactions/thank-you"
  end

  def new
    Result.all(
      ->() {
        fetch_data(params[:listing_id])
      },
      ->((listing_id, listing_model)) {
        ensure_can_start_transactions(listing_model: listing_model, current_user: @current_user, current_community: @current_community)
      }
    ).on_success { |((listing_id, listing_model, author_model, process, gateway))|
      
        current_trans = Transaction.for_person( @current_user)
        current_trans_with_address = current_trans.joins(:shipping_address).uniq.all

      if current_trans_with_address.any?
        current_user_address = current_trans_with_address.last.shipping_address
        @shipping_addresses = current_user_address
      else
        @shipping_addresses = ShippingAddress.new
      end
      booking = listing_model.unit_type == :day

      transaction_params = HashUtils.symbolize_keys({listing_id: listing_model.id}.merge(params.slice(:start_on, :end_on, :quantity, :delivery)))
      case [process[:process], gateway, booking]
      when matches([:none])
        render_free(listing_model: listing_model, author_model: author_model, community: @current_community, params: transaction_params)
      when matches([:preauthorize, __, true])
        redirect_to book_path(transaction_params)
      when matches([:preauthorize, :paypal])
        redirect_to initiate_order_path(transaction_params)
      when matches([:preauthorize, :braintree])
       redirect_to preauthorize_payment_path(transaction_params)
      when matches([:postpay])
        redirect_to post_pay_listing_path(transaction_params)
      else
        opts = "listing_id: #{listing_id}, payment_gateway: #{gateway}, payment_process: #{process}, booking: #{booking}"
        raise ArgumentError.new("Cannot find new transaction path to #{opts}")
      end
    }.on_error { |error_msg, data|
      flash[:error] = Maybe(data)[:error_tr_key].map { |tr_key| t(tr_key) }.or_else("Could not start a transaction, error message: #{error_msg}")
      redirect_to(session[:return_to_content] || root)
    }
  end

  def complete_paypal_payment(form, pay_amount, seller_paypal_email, transaction, community_id, process, listing_id, starter_id)
    @api = PayPal::SDK::AdaptivePayments.new
    # Build request object

    @pay = @api.build_pay({
    :actionType => "PAY_PRIMARY",
    :cancelUrl => (url_for :controller => 'transactions', :action => 'new'),
    :currencyCode => "CAD",
    :feesPayer => "SECONDARYONLY",
    :ipnNotificationUrl => (url_for :controller => 'payments_notifications', :action => 'ipn_hook'),
    :receiverList => {
      :receiver => [{
        :amount => pay_amount,
        :email => PAYPAL_CONFIG['email'],
        :primary => true },
        {
          :amount => (pay_amount * 0.75),
          :email => seller_paypal_email,
          :primary => false }] },
    :returnUrl => URI.join((url_for :controller => 'transactions', :action => 'paid'), '?payKey=${payKey}') })

    # Make API call & get response
    @response = @api.pay(@pay)
    if @response.success? && @response.payment_exec_status != "ERROR"
      PaypalAdaptivePayment.create(
      {
        transaction_id: transaction[:id],
        community_id: community_id,
        paypal_payment_id: @response.payKey,
        paypal_payer_id: @current_user.id
      }
      )

      TransactionStore.upsert_shipping_address(
        community_id: community_id,
        transaction_id: transaction[:id],
        addr: { :city => form[:city],
                :country => form[:country],
                :state_or_province => form[:province],
                :street1 => form[:street],
                :street2 => form[:street2],
                :name => form[:name].partition(" ").first + " " + form[:name].partition(" ").last,
                :phone => form[:phone],
                :postal_code => form[:postal]})

      MarketplaceService::Transaction::Command.transition_to(transaction[:id], "free")
    
    redirect_to @api.payment_url(@response)  # Url to complete payment
    else
      @response.error[0].message
    end
  end

  def create
    Result.all(
      ->() {
        TransactionForm.validate(params)
      },
      ->(form) {
        fetch_data(form[:listing_id])
      },
      ->(form, (_, _, _, process)) {
        default_message_if_empty(form)
        validate_form(form, process)
      },
      ->(_, (listing_id, listing_model), _) {
        ensure_can_start_transactions(listing_model: listing_model, current_user: @current_user, current_community: @current_community)
      },
      ->(form, (listing_id, listing_model, author_model, process, gateway), _, _) {
        booking_fields = Maybe(form).slice(:start_on, :end_on).select { |booking| booking.values.all? }.or_else({})
        quantity = Maybe(booking_fields).map { |b| DateUtils.duration_days(b[:start_on], b[:end_on]) }.or_else(form[:quantity])

        TransactionService::Transaction.create(
          {
            transaction: {
              community_id: @current_community.id,
              listing_id: listing_id,
              listing_title: listing_model.title,
              starter_id: @current_user.id,
              listing_author_id: author_model.id,
              unit_type: listing_model.unit_type,
              unit_price: listing_model.price,
              unit_tr_key: listing_model.unit_tr_key,
              listing_quantity: quantity,
              content: form[:message],
              booking_fields: booking_fields,
              payment_gateway: :braintree,
              # payment_gateway: process[:process] == :none ? :none : gateway, # TODO This is a bit awkward
              payment_process: process[:process]}
          })
      }
    ).on_success { |(form, (listing_id, listing_model, author_model, process, gateway), _, _, tx)|

      complete_paypal_payment(form,listing_model.price, author_model.braintree_account.email, tx[:transaction], @current_community.id, process, listing_id,  @current_user.id)
      flash[:notice] = after_create_flash(process: process) # add more params here when needed
    }.on_error { |error_msg, data|
      flash[:error] = Maybe(data)[:error_tr_key].map { |tr_key| t(tr_key) }.or_else("Could not start a transaction, error message: #{error_msg}")
      redirect_to(session[:return_to_content] || root)
    }
  end

# The paid method will check to make sure the transaction is complete.
  def paid
    payKey = params[:payKey]
    @api = PayPal::SDK::AdaptivePayments.new
    @payment_details = @api.build_payment_details({
     :payKey => payKey
      })
    paypal_status = { :completed => "COMPLETED", :incomplete => "INCOMPLETE", :pending => "PENDING", :processing => "PROCESSING" }
    @payment_details_response = @api.payment_details(@payment_details)
    if @payment_details_response.status == paypal_status[:pending] || @payment_details_response.status == paypal_status[:processing]
      logger.debug 'Transaction Not yet completed, waiting on IPN:'+@payment_details_response.status 
      render "transactions/thank-you"
    elsif @payment_details_response.status == paypal_status[:completed] || @payment_details_response.status == paypal_status[:incomplete]

      payment = PaypalAdaptivePayment.where(paypal_payment_id: payKey).first
      transaction = Transaction.where(id: payment.transaction_id).first
      id = transaction.listing_id
      @listing = Listing.where(id: id).first
      @listing.update_attribute(:open, false)
      MarketplaceService::Transaction::Command.transition_to(payment.transaction_id, "paid")

      # Move conversations for transaction into messages
       Delayed::Job.enqueue(MessageSentJob.new(transaction.conversation.messages.last.id, @current_community.id))

      logger.debug 'Transaction Completed:'+@payment_details_response.status 
      render "transactions/thank-you"
    else
      logger.debug 'Unknown Transaction type:'+@payment_details_response.status 
      render "transactions/thank-you"
    end
  end

  def show
    m_participant =
      Maybe(
        MarketplaceService::Transaction::Query.transaction_with_conversation(
        transaction_id: params[:id],
        person_id: @current_user.id,
        community_id: @current_community.id))
      .map { |tx_with_conv| [tx_with_conv, :participant] }

    m_admin =
      Maybe(@current_user.has_admin_rights?)
      .select { |can_show| can_show }
      .map {
        MarketplaceService::Transaction::Query.transaction_with_conversation(
          transaction_id: params[:id],
          community_id: @current_community.id)
      }
      .map { |tx_with_conv| [tx_with_conv, :admin] }
    transaction_conversation, role = m_participant.or_else { m_admin.or_else([]) }
    tx = TransactionService::Transaction.get(community_id: @current_community.id, transaction_id: params[:id])
         .maybe()
         .or_else(nil)
    unless tx.present? && transaction_conversation.present?
      flash[:error] = t("layouts.notifications.you_are_not_authorized_to_view_this_content")
      return redirect_to search_path
    end
    tx_model = Transaction.where(id: tx[:id]).first
    conversation = transaction_conversation[:conversation]
    listing = Listing.where(id: tx[:listing_id]).first
    messages_and_actions = TransactionViewUtils.merge_messages_and_transitions(
      TransactionViewUtils.conversation_messages(conversation[:messages], @current_community.name_display_type),
      TransactionViewUtils.transition_messages(transaction_conversation, conversation, @current_community.name_display_type))
    MarketplaceService::Transaction::Command.mark_as_seen_by_current(params[:id], @current_user.id)
    is_author =
      if role == :admin
        true
      else
        listing.author_id == @current_user.id
      end
    render "transactions/show", locals: {
      messages: messages_and_actions.reverse,
      transaction: tx,
      listing: listing,
      transaction_model: tx_model,
      conversation_other_party: person_entity_with_url(other_party(conversation)),
      is_author: is_author,
      role: role,
      message_form: MessageForm.new({sender_id: @current_user.id, conversation_id: conversation[:id]}),
      message_form_action: person_message_messages_path(@current_user, :message_id => conversation[:id]),
      price_break_down_locals: price_break_down_locals(tx)
    }
  end

  def op_status
    process_token = params[:process_token]
    resp = Maybe(process_token)
      .map { |ptok| paypal_process.get_status(ptok) }
      .select(&:success)
      .data
      .or_else(nil)
    if resp
      render :json => resp
    else
      redirect_to error_not_found_path
    end
  end

  def person_entity_with_url(person_entity)
    person_entity.merge({
      url: person_path(username: person_entity[:username]),
      display_name: PersonViewUtils.person_entity_display_name(person_entity, @current_community.name_display_type)})
  end

  def paypal_process
    PaypalService::API::Api.process
  end

  private

  def other_party(conversation)
    if @current_user.id == conversation[:other_person][:id]
      conversation[:starter_person]
    else
      conversation[:other_person]
    end
  end

  def ensure_can_start_transactions(listing_model:, current_user:, current_community:)
    error =
      if listing_model.closed?
        "layouts.notifications.you_cannot_reply_to_a_closed_offer"
      elsif listing_model.author == current_user
       "layouts.notifications.you_cannot_send_message_to_yourself"
      elsif !listing_model.visible_to?(current_user, current_community)
        "layouts.notifications.you_are_not_authorized_to_view_this_content"
      end

    if error
      Result::Error.new(error, {error_tr_key: error})
    else
      Result::Success.new
    end
  end

  def after_create_flash(process:)
    case process[:process]
    when :none
      t("layouts.notifications.message_sent")
    else
      raise NotImplementedError.new("Not implemented for process #{process}")
    end
  end

  def after_create_redirect(process:, starter_id:, transaction:)
    case process[:process]
    when :none
      person_transaction_path(person_id: starter_id, id: transaction[:id])
    else
      raise NotImplementedError.new("Not implemented for process #{process}")
    end
  end

  # Transition to Free and enqueue message
  # TODO: we are no longer using this, this happens in a 2 step 
  def after_create_actions!(process:, transaction:, community_id:)
    case process[:process]
    when :none
      MarketplaceService::Transaction::Command.transition_to(transaction[:id], "free")

      # TODO: remove references to transaction model
      transaction = Transaction.find(transaction[:id])

      Delayed::Job.enqueue(MessageSentJob.new(transaction.conversation.messages.last.id, community_id))
    else
      raise NotImplementedError.new("Not implemented for process #{process}")
    end
  end


  def after_create_actions!(process:, transaction:, community_id:)
    case process[:process]
    when :none
      # TODO Do I really have to do the state transition here?
      # Shouldn't it be handled by the TransactionService
      MarketplaceService::Transaction::Command.transition_to(transaction[:id], "free")

      # TODO: remove references to transaction model
      transaction = Transaction.find(transaction[:id])

      Delayed::Job.enqueue(MessageSentJob.new(transaction.conversation.messages.last.id, community_id))
    else
      raise NotImplementedError.new("Not implemented for process #{process}")
    end
  end

  # Fetch all related data based on the listing_id
  #
  # Returns: Result::Success([listing_id, listing_model, author, process, gateway])
  #
  def fetch_data(listing_id)
    Result.all(
      ->() {
        if listing_id.nil?
          Result::Error.new("No listing ID provided")
        else
          Result::Success.new(listing_id)
        end
      },
      ->(l_id) {
        # TODO Do not use Models directly. The data should come from the APIs
#666 - wat.
        Maybe(@current_community.listings.where(id: l_id).first)
          .map     { |listing_model| Result::Success.new(listing_model) }
          .or_else { Result::Error.new("Cannot find listing with id #{l_id}") }
      },
      ->(_, listing_model) {
        # TODO Do not use Models directly. The data should come from the APIs
        Result::Success.new(listing_model.author)
      },
      ->(_, listing_model, *rest) {
        TransactionService::API::Api.processes.get(community_id: @current_community.id, process_id: listing_model.transaction_process_id)
      },
      ->(*) {
        Result::Success.new(MarketplaceService::Community::Query.payment_type(@current_community.id))
      }
    )
  end

  def validate_form(form_params, process)
    if process[:process] == :none && form_params[:message].blank?
      Result::Error.new("Message cannot be empty")
    else
      Result::Success.new
    end
  end

  def default_message_if_empty(form_params)
    if form_params[:message].blank?
      form_params[:message] = "Payment Initiated"
    else
    end
  end

  def price_break_down_locals(tx)
    if tx[:payment_process] == :none && tx[:listing_price].cents == 0
      nil
    else
      unit_type = tx[:unit_type].present? ? ListingViewUtils.translate_unit(tx[:unit_type], tx[:unit_tr_key]) : nil
      localized_selector_label = tx[:unit_type].present? ? ListingViewUtils.translate_quantity(tx[:unit_type], tx[:unit_selector_tr_key]) : nil
      booking = !!tx[:booking]
      quantity = tx[:listing_quantity]
      show_subtotal = !!tx[:booking] || quantity.present? && quantity > 1 || tx[:shipping_price].present?
      total_label = (tx[:payment_process] != :preauthorize) ? t("transactions.price") : t("transactions.total")

      TransactionViewUtils.price_break_down_locals({
        listing_price: tx[:listing_price],
        localized_unit_type: unit_type,
        localized_selector_label: localized_selector_label,
        booking: booking,
        start_on: booking ? tx[:booking][:start_on] : nil,
        end_on: booking ? tx[:booking][:end_on] : nil,
        duration: booking ? tx[:booking][:duration] : nil,
        quantity: quantity,
        subtotal: show_subtotal ? tx[:listing_price] * quantity : nil,
        total: Maybe(tx[:payment_total]).or_else(tx[:checkout_total]),
        shipping_price: tx[:shipping_price],
        total_label: total_label
      })
    end
  end

  def render_free(listing_model:, author_model:, community:, params:)
    # TODO This data should come from API
    listing = {
      id: listing_model.id,
      title: listing_model.title,
      action_button_label: t(listing_model.action_button_tr_key),
    }
    author = {
      display_name: PersonViewUtils.person_display_name(author_model, community),
      username: author_model.username
    }

    unit_type = listing_model.unit_type.present? ? ListingViewUtils.translate_unit(listing_model.unit_type, listing_model.unit_tr_key) : nil
    localized_selector_label = listing_model.unit_type.present? ? ListingViewUtils.translate_quantity(listing_model.unit_type, listing_model.unit_selector_tr_key) : nil
    booking_start = Maybe(params)[:start_on].map { |d| TransactionViewUtils.parse_booking_date(d) }.or_else(nil)
    booking_end = Maybe(params)[:end_on].map { |d| TransactionViewUtils.parse_booking_date(d) }.or_else(nil)
    booking = !!(booking_start && booking_end)
    duration = booking ? DateUtils.duration_days(booking_start, booking_end) : nil
    quantity = Maybe(booking ? DateUtils.duration_days(booking_start, booking_end) : TransactionViewUtils.parse_quantity(params[:quantity])).or_else(1)
    total_label = t("transactions.price")

    m_price_break_down = Maybe(listing_model).select { |l_model| l_model.price.present? }.map { |l_model|
      TransactionViewUtils.price_break_down_locals(
        {
          listing_price: l_model.price,
          localized_unit_type: unit_type,
          localized_selector_label: localized_selector_label,
          booking: booking,
          start_on: booking_start,
          end_on: booking_end,
          duration: duration,
          quantity: quantity,
          subtotal: quantity != 1 ? l_model.price * quantity : nil,
          total: l_model.price * quantity,
          shipping_price: nil,
          total_label: total_label
        })
    }

    render "transactions/new", locals: {
             listing: listing,
             author: author,
             action_button_label: t(listing_model.action_button_tr_key),
             m_price_break_down: m_price_break_down,
             booking_start: booking_start,
             booking_end: booking_end,
             quantity: quantity,
             form_action: person_transactions_path(person_id: @current_user, listing_id: listing_model.id)
           }
  end

end
