require "bundler/setup"
require "json"
require "bigdecimal"
require "json-schema"
require 'date'

class Drivy
  attr_accessor :data
  attr_accessor :is_valid_input
  attr_reader :deductible_reduction_price_per_day
  attr_reader :assistance_price_per_day


  def initialize(in_path)
    # constant prices
    @deductible_reduction_price_per_day = BigDecimal(400)
    @assistance_price_per_day = BigDecimal(100)

    @is_valid_input = false

    json_file = File.read(in_path)
    json = JSON.parse(json_file)

    errors = self.validate_input_json(json)
    if errors.length > 0
      # display json errors nicely
      puts errors
    else
      @is_valid_input = true
      @data = self.get_structure(json)
    end
  end

  def get_structure(json)
    cars = json['cars']
    rentals = json['rentals']
    rental_modifications = json['rental_modifications']

    rentals_out = []
    rentals.each do |rental|
      start_date = Date.parse(rental['start_date'])
      end_date = Date.parse(rental['end_date'])
      raise "start_date must be earlier than end_date" unless start_date <= end_date

      rental_id = rental['id']
      car_id = rental['car_id']

      # cars
      related_cars = cars.select{|c| c['id'] == car_id}
      raise "only one car can match an id" unless related_cars.length == 1
      car = related_cars[0]

      #modifications
      related_modifications = rental_modifications.select{|r| r['rental_id'] == rental_id}

      results = get_rental_modifications(
          start_date,
          end_date,
          car,
          rental,
          related_modifications,
      )
      next if not results

      results.each do |el|
        modification_id = el[:id]
        driver, driver_type = el[:values][:driver]
        owner, owner_type = el[:values][:owner]
        insurance, insurance_type = el[:values][:insurance]
        assistance, assistance_type = el[:values][:assistance]
        drivy, drivy_type = el[:values][:drivy]

        rentals_out.push({
          id: modification_id,
          rental_id: rental_id,
          actions: [
            {
                who: "driver",
                type: driver_type,
                amount: driver.to_i
            },
            {
                who: "owner",
                type: owner_type,
                amount: owner.to_i
            },
            {
                who: "insurance",
                type: insurance_type,
                amount: insurance.to_i
            },
            {
                who: "assistance",
                type: assistance_type,
                amount: assistance.to_i
            },
            {
                who: "drivy",
                type: drivy_type,
                amount: drivy.to_i
            }
          ]
        })
      end
    end
    out = {
      rental_modifications: rentals_out
    }
  end

  def save_json(out_path)
    return if not @is_valid_input

    File.open(out_path, 'w') do |f|
      f.puts(JSON.pretty_generate(@data))
    end
  end

  def test_diff(test_out_path, out_path)
    # minimal testing
    if FileUtils.identical?(test_out_path, out_path)
      puts "ok"
    else
      puts "there are differences"
    end
  end

  def validate_input_json(json)
    # validate agains this schema
    # not everything can be validated here
    #
    # it covers:
    #   - required fields and basic types
    #
    # it does not cover:
    #   - one field or another but not bot required
    #   - date type
    #   - ids that need to point to a valid record
    #
    # for the rest, check programatically

    schema = {
       "type" => "object",
       "required" => ["cars", "rentals", "rental_modifications"],
       "properties" => {
           "cars" => {
               "type" => "array",
               "items" => {
                   "type" => "object",
                   "required" => ["id", "price_per_day", "price_per_km"],
                   "properties" => {
                       "id" => { "type" => "integer" },
                       "price_per_day" => { "type" => "integer" },
                       "price_per_km" => { "type" => "integer" },
                   }
               }
           },
           "rentals" => {
               "type" => "array",
               "items" => {
                   "type" => "object",
                   "required" => ["id", "car_id", "start_date", "end_date", "distance", "deductible_reduction"],
                   "properties" => {
                       "id" => { "type" => "integer" },
                       "car_id" => { "type" => "integer" },
                       "start_date" => { "type" => "string" },
                       "end_date" => { "type" => "string" },
                       "distance" => { "type" => "integer" },
                       "deductible_reduction" => { "type" => "boolean" },
                   }
               }
           },
           "rental_modifications" => {
               "type" => "array",
               "items" => {
                   "type" => "object",
                   "required" => ["id", "rental_id"],
                   "properties" => {
                       "id" => { "type" => "integer" },
                       "rental_id" => { "type" => "integer" },
                       "start_date" => { "type" => "string" },
                       "end_date" => { "type" => "string" },
                       "distance" => { "type" => "integer" },
                   }
               }
           },
       }
    }
    # array of errors
    return JSON::Validator.fully_validate(schema, json)
  end

  private
    def get_debit_credit_for_dates(start_date, end_date, distance, car, has_deductible_reduction)
      # Who pays and who receives money
      # for all the actors involved

      # at least 1 day
      days = (end_date - start_date).to_i + 1
      raise "a positive number of days is expected" unless days > 0

      rental_price = calc_price(
          days,
          car['price_per_day'],
          distance,
          car['price_per_km']
      )

      insurance_fee, assistance_fee, drivy_fee = calc_commission(days, rental_price)
      commission_total = (insurance_fee + assistance_fee + drivy_fee)
      deductible = calc_deductible(days, has_deductible_reduction)

      # driver pays
      driver = rental_price + deductible

      # the rest receive
      owner = rental_price - commission_total
      insurance = insurance_fee
      assistance = assistance_fee
      drivy = drivy_fee + deductible


      return driver, owner, insurance, assistance, drivy
    end

    def get_rental_modifications(start_date, end_date, car, rental, rental_modifications)
      # return lists of rental modifications with debit/credit
      # per actor

      # we ignore rentals without modifications
      if rental_modifications.length == 0
        return []
      end

      distance = rental['distance']
      has_deductible_reduction = rental['deductible_reduction']

      # original rental
      driver, owner, insurance, assistance, drivy = get_debit_credit_for_dates(
          start_date,
          end_date,
          distance,
          car,
          has_deductible_reduction,
      )

      # modifications
      # whatever is not modified we take from the original
      ret = []
      rental_modifications.each do |m|
        if m['start_date'].nil?
          mod_start_date = start_date
        else
          mod_start_date = Date.parse(m['start_date'])
        end

        if m['end_date'].nil?
          mod_end_date = end_date
        else
          mod_end_date = Date.parse(m['end_date'])
        end

        if m['distance'].nil?
          mod_distance = distance
        else
          mod_distance = m['distance']
        end
        raise "new start date cannot be earlier" unless mod_start_date >= start_date
        raise "new end date cannot be earlier" unless mod_end_date >= end_date


        driver_after, owner_after, insurance_after, assistance_after, drivy_after = get_debit_credit_for_dates(
            mod_start_date,
            mod_end_date,
            mod_distance,
            car,
            has_deductible_reduction,
        )
        # puts "--driver", driver.to_i, driver_after.to_i
        # puts "--owner", owner.to_i, owner_after.to_i
        # puts "--insurance", insurance.to_i, insurance_after.to_i
        # puts "--assistance", assistance.to_i, assistance_after.to_i
        # puts "--drivy", drivy.to_i, drivy_after.to_i

        driver_delta = get_delta(driver, driver_after, is_debit: true)
        owner_delta = get_delta(owner, owner_after)
        insurance_delta = get_delta(insurance, insurance_after)
        assistance_delta = get_delta(assistance, assistance_after)
        drivy_delta = get_delta(drivy, drivy_after)

        ret.push(
          {
            id: m['id'],
            values: {
                driver: driver_delta,
                owner: owner_delta,
                insurance: insurance_delta,
                assistance: assistance_delta,
                drivy: drivy_delta,
            }
          }
        )
      end
      return ret

    end

    def calc_price(days, price_per_day, distance, price_per_km)
      # discount gets calculated as each day passes
      # _not_ simply at the end
      # use BigDecimal, since there are divisions and we could lose precision

      time_component = BigDecimal(0)
      daily_discount = BigDecimal(0)
      1.upto(days) do |day_num|
        # biggest first to match the biggest discount
        if day_num > 10
          daily_discount = BigDecimal(50)
        elsif day_num > 4
           daily_discount = BigDecimal(30)
        elsif day_num > 1
          daily_discount = BigDecimal(10)
        end

        per_day = BigDecimal(price_per_day)
        discount = (per_day * daily_discount) / BigDecimal(100)
        discounted_price_per_day = per_day - discount

        time_component = time_component + discounted_price_per_day
      end

      distance_component = BigDecimal(distance) * BigDecimal(price_per_km)
      price = (time_component + distance_component)
    end

    def calc_commission(days, rental_price)
      raise "needs to be BigDecimal" unless rental_price.class == BigDecimal

      commission = (rental_price * BigDecimal(30)) / BigDecimal(100)
      insurance = commission / BigDecimal(2)

      # one euro a day, remember: cents
      roadside_assistance = BigDecimal(days) * @assistance_price_per_day
      to_us = commission - insurance - roadside_assistance

      return insurance, roadside_assistance, to_us
    end

    def calc_deductible(days, has_deductible_reduction)
      raise "needs to be a boolean" unless [true, false].include? has_deductible_reduction

      if has_deductible_reduction
        # 4€/day, in cents
        return BigDecimal(days) * @deductible_reduction_price_per_day
      else
        return BigDecimal(0)
      end
    end

    def get_delta(amount_before, amount_after, is_debit: false)
      # some actors receive money (debit)
      # and some pay money (credit)
      # return delta and also if the amount
      # is debit or credit

      delta = amount_after - amount_before

      if is_debit
        if delta < 0
          type = "credit"
        else
          type = "debit"
        end
      end

      if not is_debit
        if delta < 0
          type = "debit"
        else
          type = "credit"
        end
      end

      # get absolute number
      # since we already keep track of credit|debit
      return delta.abs, type
    end
end


in_path = 'data.json'
out_path = 'output2.json'

d = Drivy.new(in_path)
d.save_json(out_path)
# uncomment to test
# test_out_path = 'output.json'
# d.test_diff(test_out_path, out_path)
