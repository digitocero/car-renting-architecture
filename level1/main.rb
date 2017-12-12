require "bundler/setup"
require "json"
# TODO: use json schema o validate json structure
# require "json-schema"

def main(in_path, out_path, test_out_path, is_test)
  file = File.read(in_path)
  el = JSON.parse(file)

  cars = el['cars']
  rentals = el['rentals']

  # get data structure
  rentals_out = []
  rentals.each do |r|
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

    time_component = days * car['price_per_day']
    distance_component = r['distance'] * car['price_per_km']
    customer_price = time_component + distance_component

    rentals_out.push({
        id: rental_id,
        price: customer_price
     })
  end
  out = {
      rentals: rentals_out
  }


  # persist to json
  File.open(out_path, 'w') do |f|
    f.puts(JSON.pretty_generate(out))
  end

  # minimal testing
  if is_test
    if FileUtils.identical?(test_out_path, out_path)
      puts "ok"
    else
      puts "there are differences"
    end
  end

end


in_path = 'data.json'
out_path = 'output2.json'
test_out_path = 'output.json'
# is_test = true
is_test = false

main(in_path, out_path, test_out_path, is_test)
