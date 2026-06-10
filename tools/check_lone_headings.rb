Dir.glob("*.md").sort.each do |f|
  lines = File.readlines(f)
  in_code = false
  heads = []   # [level, text, lineno]
  lines.each_with_index do |l, i|
    in_code = !in_code if l =~ /^(```|~~~)/
    next if in_code
    if l =~ /^(\#{1,6})\s+(.+)/
      heads << [$1.length, $2.strip, i + 1]
    end
  end
  heads.each_with_index do |(lv, text, ln), idx|
    children = []
    heads[(idx + 1)..].each do |(lv2, t2, ln2)|
      break if lv2 <= lv
      children << [t2, ln2] if lv2 == lv + 1
    end
    if children.size == 1
      puts "#{f}:#{ln} 「#{text}」(H#{lv}) の子見出しが 1 つだけ → #{f}:#{children[0][1]} 「#{children[0][0]}」"
    end
  end
end
