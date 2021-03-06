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

    # get data structure
    rentals_out = []
    rentals.each do |r|
      # puts Date.parse(r['start_date'])
      start_date = Date.parse(r['start_date'])
      end_date = Date.parse(r['end_date'])
      raise "start_date must be earlier than end_date" unless start_date <= end_date

      # at least 1 day
      days = (end_date - start_date).to_i + 1
      raise "a positive number of days is expected" unless days > 0

      rental_id = r['id']
      car_id = r['car_id']
      cars_selected = cars.select{|c| c['id'] == car_id}
      raise "only one car can match an id" unless cars_selected.length == 1
      car = cars_selected[0]

      rental_price = calc_price(
        days,
        car['price_per_day'],
        r['distance'],
        car['price_per_km']
      )

      insurance_fee, assistance_fee, drivy_fee = calc_commission(days, rental_price)
      deductible_profit = calc_deductible_profit(days, r['deductible_reduction'])

      rentals_out.push({
        id: rental_id,
        price: rental_price.to_i,
        options: {
            deductible_reduction: deductible_profit.to_i
        },
        commission: {
          insurance_fee: insurance_fee.to_i,
          assistance_fee: assistance_fee.to_i,
          drivy_fee: drivy_fee.to_i
        }
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

    def calc_deductible_profit(days, has_deductible_reduction)
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
