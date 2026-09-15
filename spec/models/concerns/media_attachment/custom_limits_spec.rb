# frozen_string_literal: true

require 'rails_helper'

# 自鯖用カスタム（メディアアップロード上限の緩和）が効いているかの確認。
# 落ちた場合は app/models/media_attachment.rb の `include MediaAttachment::CustomLimits` が
# 上流追従で消えたか、位置がずれている（詳細は concern 側のコメントを参照）。
RSpec.describe MediaAttachment::CustomLimits do
  describe 'MediaAttachment の上限定数' do
    it 'ファイルサイズの上限を緩和している' do
      expect(MediaAttachment::IMAGE_LIMIT).to eq 80.megabytes
      expect(MediaAttachment::VIDEO_LIMIT).to eq 400.megabytes
    end

    it '動画の解像度・フレームレート・フレーム数の上限を緩和している' do
      expect(MediaAttachment::MAX_VIDEO_MATRIX_LIMIT).to eq 33_177_600
      expect(MediaAttachment::MAX_VIDEO_FRAME_RATE).to eq 240
      expect(MediaAttachment::MAX_VIDEO_FRAMES).to eq 72_000
    end

    it '画像 original スタイルの画素数上限を緩和し、small スタイルは上流のまま' do
      expect(MediaAttachment::IMAGE_STYLES.dig(:original, :pixels)).to eq 33_177_600
      expect(MediaAttachment::IMAGE_STYLES.dig(:small, :pixels)).to eq 230_400
    end

    it '置き換えた IMAGE_STYLES は上流と同様に凍結されている' do
      expect(MediaAttachment::IMAGE_STYLES).to be_frozen
      expect(MediaAttachment::IMAGE_STYLES[:original]).to be_frozen
    end
  end

  describe '上限定数から派生する設定' do
    # include が派生定数の定義より前に置かれていることの確認
    it 'IMAGE_CONVERTED_STYLES が緩和後の画素数を使う' do
      expect(MediaAttachment::IMAGE_CONVERTED_STYLES.dig(:original, :pixels)).to eq MediaAttachment::MAX_VIDEO_MATRIX_LIMIT
    end

    it 'VIDEO_FORMAT と VIDEO_STYLES が緩和後のフレームレート・フレーム数を使う' do
      expect(MediaAttachment::VIDEO_FORMAT[:vfr_frame_rate_threshold]).to eq MediaAttachment::MAX_VIDEO_FRAME_RATE
      expect(MediaAttachment::VIDEO_FORMAT.dig(:convert_options, :output, 'frames:v')).to eq MediaAttachment::MAX_VIDEO_FRAMES
      expect(MediaAttachment::VIDEO_STYLES.dig(:original, :vfr_frame_rate_threshold)).to eq MediaAttachment::MAX_VIDEO_FRAME_RATE
      expect(MediaAttachment::VIDEO_CONVERTED_STYLES.dig(:original, :convert_options, :output, 'frames:v')).to eq MediaAttachment::MAX_VIDEO_FRAMES
    end
  end

  describe 'サイズバリデーション' do
    # 上流の上限 (画像 16MB / 動画 99MB) は超えるが、自鯖の上限には収まるサイズ
    it '上流の上限を超える画像を受け付ける' do
      media = Fabricate.build(:media_attachment, type: :image)
      media.file_file_size = 50.megabytes

      expect(media).to be_valid
    end

    it '上流の上限を超える動画を受け付ける' do
      media = Fabricate.build(:media_attachment, type: :video)
      media.file_file_size = 300.megabytes

      expect(media).to be_valid
    end

    it '自鯖の上限を超える画像は拒否する' do
      media = Fabricate.build(:media_attachment, type: :image)
      media.file_file_size = 100.megabytes

      expect(media).to_not be_valid
    end
  end
end
