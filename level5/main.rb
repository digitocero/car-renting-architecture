require "bundler/setup"
require "json"
require "bigdecimal"
# TODO: use json schema to validate json structure
# require "json-schema"
require 'date'

class Drivy
  attr_accessor :data

  def initialize(in_path)
    @data = self.get_structure(in_path)
  end

  def get_structure(in_path)
    file = File.read(in_path)
    el = JSON.parse(file)

    cars = el['cars']
    rentals = el['rentals']

    rentals_out = []
    rentals.each do |rental|
      start_date = Date.parse(rental['start_date'])
      end_date = Date.parse(rental['end_date'])
      raise "start_date must be earlier than end_date" unless start_date <= end_date

      # at least 1 day
      days = (end_date - start_date).to_i + 1
      raise "a positive number of days is expected" unless days > 0

      rental_id = rental['id']
      car_id = rental['car_id']
      cars_selected = cars.select{|c| c['id'] == car_id}
      raise "only one car can match an id" unless cars_selected.length == 1
      car = cars_selected[0]

      driver, owner, insurance, assistance, drivy = get_debit_credit_for_all(
          days,
          car,
          rental,
      )

      rentals_out.push({
        id: rental_id,
        actions: [
          {
              who: "driver",
              type: "debit",
              amount: driver.to_i
          },
          {
              who: "owner",
              type: "credit",
              amount: owner.to_i
          },
          {
              who: "insurance",
              type: "credit",
              amount: insurance.to_i
          },
          {
              who: "assistance",
              type: "credit",
              amount: assistance.to_i
          },
          {
              who: "drivy",
              type: "credit",
              amount: drivy.to_i
          }
        ]
      })
    end
    out = {
      rentals: rentals_out
    }
  end

  def save_json(out_path)
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

  private
    def get_debit_credit_for_all(days, car, rental)
      # Who pays and who receives money
      # for all the actors involved

      rental_price = calc_price(
          days,
          car['price_per_day'],
          rental['distance'],
          car['price_per_km']
      )

      insurance_fee, assistance_fee, drivy_fee = calc_commission(days, rental_price)
      commission_total = (insurance_fee + assistance_fee + drivy_fee)
      deductible = calc_deductible(days, rental['deductible_reduction'])

      # driver pays
      driver = rental_price + deductible

      # the rest receive
      owner = rental_price - commission_total
      insurance = insurance_fee
      assistance = assistance_fee
      drivy = drivy_fee + deductible

      return driver, owner, insurance, assistance, drivy
    end

    def calc_price(days, price_per_day, distance, price_per_km)
      # discount gets calculated as each day passes
      # _not_ simply at the end
      # use BigDecimal, since there are divisions and we could lose precision

      time_component = BigDecimal.new(0)
      daily_discount = BigDecimal.new(0)
      1.upto(days) do |day_num|
        # biggest first to match the biggest discount
        if day_num > 10
          daily_discount = BigDecimal.new(50)
        elsif day_num > 4
           daily_discount = BigDecimal.new(30)
        elsif day_num > 1
          daily_discount = BigDecimal.new(10)
        end

        per_day = BigDecimal.new(price_per_day)
        discount = (per_day * daily_discount) / BigDecimal.new(100)
        discounted_price_per_day = per_day - discount

        time_component = time_component + discounted_price_per_day
      end

      distance_component = BigDecimal.new(distance) * BigDecimal.new(price_per_km)
      price = (time_component + distance_component)
    end

    def calc_commission(days, rental_price)
      raise "needs to be BigDecimal" unless rental_price.class == BigDecimal

      commission = (rental_price * BigDecimal.new(30)) / BigDecimal.new(100)
      insurance = commission / BigDecimal.new(2)

      # one euro a day, remember: cents
      roadside_assistance = BigDecimal.new(days) * 100
      to_us = commission - insurance - roadside_assistance

      return insurance, roadside_assistance, to_us
    end

    def calc_deductible(days, has_deductible_reduction)
      raise "needs to be a boolean" unless [true, false].include? has_deductible_reduction

      if has_deductible_reduction
        # 4€/day, in cents
        return BigDecimal.new(days) * 400
      else
        return BigDecimal.new(0)
      end
    end
end


in_path = 'data.json'
out_path = 'output2.json'
test_out_path = 'output.json'

d = Drivy.new(in_path)
d.save_json(out_path)
# uncomment to test
# d.test_diff(test_out_path, out_path)
