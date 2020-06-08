class Campaign
  def initialize(condition, *qualifiers)
    @condition = (condition.to_s + '?').to_sym
    @qualifiers = PostCartAmountQualifier ? [] : [] rescue qualifiers.compact
    @line_item_selector = qualifiers.last unless @line_item_selector
    qualifiers.compact.each do |qualifier|
      is_multi_select = qualifier.instance_variable_get(:@conditions).is_a?(Array)
      if is_multi_select
        qualifier.instance_variable_get(:@conditions).each do |nested_q|
          @post_amount_qualifier = nested_q if nested_q.is_a?(PostCartAmountQualifier)
          @qualifiers << qualifier
        end
      else
        @post_amount_qualifier = qualifier if qualifier.is_a?(PostCartAmountQualifier)
        @qualifiers << qualifier
      end
    end if @qualifiers.empty?
  end

  def qualifies?(cart)
    return true if @qualifiers.empty?
    @unmodified_line_items = cart.line_items.map do |item|
      new_item = item.dup
      new_item.instance_variables.each do |var|
        val = item.instance_variable_get(var)
        new_item.instance_variable_set(var, val.dup) if val.respond_to?(:dup)
      end
      new_item
    end if @post_amount_qualifier
    @qualifiers.send(@condition) do |qualifier|
      is_selector = false
      if qualifier.is_a?(Selector) || qualifier.instance_variable_get(:@conditions).any? { |q| q.is_a?(Selector) }
        is_selector = true
      end rescue nil
      if is_selector
        raise "Missing line item match type" if @li_match_type.nil?
        cart.line_items.send(@li_match_type) { |item| qualifier.match?(item) }
      else
        qualifier.match?(cart, @line_item_selector)
      end
    end
  end

  def run_with_hooks(cart)
    before_run(cart) if respond_to?(:before_run)
    run(cart)
    after_run(cart)
  end

  def after_run(cart)
    @discount.apply_final_discount if @discount && @discount.respond_to?(:apply_final_discount)
    revert_changes(cart) unless @post_amount_qualifier.nil? || @post_amount_qualifier.match?(cart)
  end

  def revert_changes(cart)
    cart.instance_variable_set(:@line_items, @unmodified_line_items)
  end
end

class ShippingDiscount < Campaign
  def initialize(condition, customer_qualifier, cart_qualifier, li_match_type, line_item_qualifier, rate_selector, discount)
    super(condition, customer_qualifier, cart_qualifier, line_item_qualifier)
    @li_match_type = (li_match_type.to_s + '?').to_sym
    @rate_selector = rate_selector
    @discount = discount
  end

  def run(rates, cart)
    raise "Campaign requires a discount" unless @discount
    return unless qualifies?(cart)
    rates.each do |rate|
      next unless @rate_selector.nil? || @rate_selector.match?(rate)
      @discount.apply(rate)
    end
  end
end

class Qualifier
  def partial_match(match_type, item_info, possible_matches)
    match_type = (match_type.to_s + '?').to_sym
    if item_info.kind_of?(Array)
      possible_matches.any? do |possibility|
        item_info.any? do |search|
          search.send(match_type, possibility)
        end
      end
    else
      possible_matches.any? do |possibility|
        item_info.send(match_type, possibility)
      end
    end
  end

  def compare_amounts(compare, comparison_type, compare_to)
    case comparison_type
      when :greater_than
        return compare > compare_to
      when :greater_than_or_equal
        return compare >= compare_to
      when :less_than
        return compare < compare_to
      when :less_than_or_equal
        return compare <= compare_to
      when :equal_to
        return compare == compare_to
      else
        raise "Invalid comparison type"
    end
  end
end

class CustomerAcceptsMarketingQualifier < Qualifier
  def initialize(match_type)
    @invert = match_type == :does_not
  end

  def match?(cart, selector = nil)
    return false if cart.customer.nil?
    return @invert ^ cart.customer.accepts_marketing?
  end
end

class AndSelector
  def initialize(*conditions)
    @conditions = conditions.compact
  end

  def match?(item, selector = nil)
    @conditions.all? do |condition|
      if selector
        condition.match?(item, selector)
      else
        condition.match?(item)
      end
    end
  end
end

class CartAmountQualifier < Qualifier
  def initialize(behaviour, comparison_type, amount)
    @behaviour = behaviour
    @comparison_type = comparison_type
    @amount = Money.new(cents: amount * 100)
  end

  def match?(cart, selector = nil)
    total = cart.subtotal_price
    if @behaviour == :item || @behaviour == :diff_item
      total = cart.line_items.reduce(Money.zero) do |total, item|
        total + (selector&.match?(item) ? item.line_price : Money.zero)
      end
    end
    case @behaviour
      when :cart, :item
        compare_amounts(total, @comparison_type, @amount)
      when :diff_cart
        compare_amounts(cart.subtotal_price_was - @amount, @comparison_type, total)
      when :diff_item
        original_line_total = cart.line_items.reduce(Money.zero) do |total, item|
          total + (selector&.match?(item) ? item.original_line_price : Money.zero)
        end
        compare_amounts(original_line_total - @amount, @comparison_type, total)
    end
  end
end

class NoCodeQualifier < Qualifier
  def match?(cart, selector = nil)
    return true if cart.discount_code.nil?
    false
  end
end

class Selector
  def partial_match(match_type, item_info, possible_matches)
    match_type = (match_type.to_s + '?').to_sym
    if item_info.kind_of?(Array)
      possible_matches.any? do |possibility|
        item_info.any? do |search|
          search.send(match_type, possibility)
        end
      end
    else
      possible_matches.any? do |possibility|
        item_info.send(match_type, possibility)
      end
    end
  end
end

class RateNameSelector < Selector
  def initialize(match_type, match_condition, names)
    @match_condition = match_condition
    @invert = match_type == :does_not
    @names = names.map(&:downcase)
  end

  def match?(shipping_rate)
    name = shipping_rate.name.downcase
    case @match_condition
      when :match
        return @invert ^ @names.include?(name)
      else
        return @invert ^ partial_match(@match_condition, name, @names)
    end
  end
end

class PercentageDiscount
  def initialize(percent, message)
    @percent = Decimal.new(percent) / 100
    @message = message
  end

  def apply(rate)
    rate.apply_discount(rate.price * @percent, { message: @message })
  end
end

CAMPAIGNS = [
  ShippingDiscount.new(
    :all,
    CustomerAcceptsMarketingQualifier.new(
      :does
    ),
    AndSelector.new(
      CartAmountQualifier.new(
        :cart,
        :greater_than_or_equal,
        100
      ),
      NoCodeQualifier.new(),
      nil
    ),
    :any,
    nil,
    RateNameSelector.new(
      :does,
      :match,
      ["Priority Shipping"]
    ),
    PercentageDiscount.new(
      100,
      "Free Shipping"
    )
  )
].freeze

CAMPAIGNS.each do |campaign|
  campaign.run(Input.shipping_rates, Input.cart)
end

Output.shipping_rates = Input.shipping_rates

