# frozen_string_literal: true

require 'rails_helper'
require 'file_store/s3_store'

describe UploadsController do
  describe '#create' do
    it 'requires you to be logged in' do
      post "/uploads.json"
      expect(response.status).to eq(403)
    end

    context 'logged in' do
      let!(:user) { sign_in(Fabricate(:user)) }

      let(:logo) do
        Rack::Test::UploadedFile.new(file_from_fixtures("logo.png"))
      end

      let(:fake_jpg) do
        Rack::Test::UploadedFile.new(file_from_fixtures("fake.jpg"))
      end

      let(:text_file) do
        Rack::Test::UploadedFile.new(File.new("#{Rails.root}/LICENSE.txt"))
      end

      it 'expects a type' do
        post "/uploads.json", params: { file: logo }
        expect(response.status).to eq(400)
      end

      it 'is successful with an image' do
        post "/uploads.json", params: { file: logo, type: "avatar" }
        expect(response.status).to eq 200
        expect(JSON.parse(response.body)["id"]).to be_present
        expect(Jobs::CreateAvatarThumbnails.jobs.size).to eq(1)
      end

      it 'is successful with an attachment' do
        SiteSetting.authorized_extensions = "*"

        post "/uploads.json", params: { file: text_file, type: "composer" }
        expect(response.status).to eq 200

        expect(Jobs::CreateAvatarThumbnails.jobs.size).to eq(0)
        id = JSON.parse(response.body)["id"]
        expect(id).to be
      end

      it 'is successful with api' do
        SiteSetting.authorized_extensions = "*"
        api_key = Fabricate(:api_key, user: user).key

        url = "http://example.com/image.png"
        png = File.read(Rails.root + "spec/fixtures/images/logo.png")

        stub_request(:get, url).to_return(status: 200, body: png)

        post "/uploads.json", params: { url: url, type: "avatar", api_key: api_key, api_username: user.username }

        json = ::JSON.parse(response.body)

        expect(response.status).to eq(200)
        expect(Jobs::CreateAvatarThumbnails.jobs.size).to eq(1)
        expect(json["id"]).to be_present
        expect(json["short_url"]).to eq("upload://qUm0DGR49PAZshIi7HxMd3cAlzn.png")
      end

      it 'correctly sets retain_hours for admins' do
        sign_in(Fabricate(:admin))

        post "/uploads.json", params: {
          file: logo,
          retain_hours: 100,
          type: "profile_background",
        }

        id = JSON.parse(response.body)["id"]
        expect(Jobs::CreateAvatarThumbnails.jobs.size).to eq(0)
        expect(Upload.find(id).retain_hours).to eq(100)
      end

      it 'requires a file' do
        post "/uploads.json", params: { type: "composer" }

        expect(Jobs::CreateAvatarThumbnails.jobs.size).to eq(0)
        message = JSON.parse(response.body)
        expect(response.status).to eq 422
        expect(message["errors"]).to contain_exactly(I18n.t("upload.file_missing"))
      end

      it 'properly returns errors' do
        SiteSetting.authorized_extensions = "*"
        SiteSetting.max_attachment_size_kb = 1

        post "/uploads.json", params: { file: text_file, type: "avatar" }

        expect(response.status).to eq(422)
        expect(Jobs::CreateAvatarThumbnails.jobs.size).to eq(0)
        errors = JSON.parse(response.body)["errors"]
        expect(errors.first).to eq(I18n.t("upload.attachments.too_large", max_size_kb: 1))
      end

      it 'ensures allow_uploaded_avatars is enabled when uploading an avatar' do
        SiteSetting.allow_uploaded_avatars = false
        post "/uploads.json", params: { file: logo, type: "avatar" }
        expect(response.status).to eq(422)
      end

      it 'ensures sso_overrides_avatar is not enabled when uploading an avatar' do
        SiteSetting.sso_overrides_avatar = true
        post "/uploads.json", params: { file: logo, type: "avatar" }
        expect(response.status).to eq(422)
      end

      it 'always allows admins to upload avatars' do
        sign_in(Fabricate(:admin))
        SiteSetting.allow_uploaded_avatars = false

        post "/uploads.json", params: { file: logo, type: "avatar" }
        expect(response.status).to eq(200)
      end

      it 'allows staff to upload any file in PM' do
        SiteSetting.authorized_extensions = "jpg"
        SiteSetting.allow_staff_to_upload_any_file_in_pm = true
        user.update_columns(moderator: true)

        post "/uploads.json", params: {
          file: text_file,
          type: "composer",
          for_private_message: "true",
        }

        expect(response.status).to eq(200)
        id = JSON.parse(response.body)["id"]
        expect(Upload.last.id).to eq(id)
      end

      it 'allows staff to upload supported images for site settings' do
        SiteSetting.authorized_extensions = ''
        user.update!(admin: true)

        post "/uploads.json", params: {
          file: logo,
          type: "site_setting",
          for_site_setting: "true",
        }

        expect(response.status).to eq(200)
        id = JSON.parse(response.body)["id"]

        upload = Upload.last

        expect(upload.id).to eq(id)
        expect(upload.original_filename).to eq('logo.png')
      end

      it 'respects `authorized_extensions_for_staff` setting when staff upload file' do
        SiteSetting.authorized_extensions = ""
        SiteSetting.authorized_extensions_for_staff = "*"
        user.update_columns(moderator: true)

        post "/uploads.json", params: {
          file: text_file,
          type: "composer",
        }

        expect(response.status).to eq(200)
        data = JSON.parse(response.body)
        expect(data["id"]).to be_present
      end

      it 'ignores `authorized_extensions_for_staff` setting when non-staff upload file' do
        SiteSetting.authorized_extensions = ""
        SiteSetting.authorized_extensions_for_staff = "*"

        post "/uploads.json", params: {
          file: text_file,
          type: "composer",
        }

        data = JSON.parse(response.body)
        expect(data["errors"].first).to eq(I18n.t("upload.unauthorized", authorized_extensions: ''))
      end

      it 'returns an error when it could not determine the dimensions of an image' do
        post "/uploads.json", params: { file: fake_jpg, type: "composer" }

        expect(response.status).to eq(422)
        expect(Jobs::CreateAvatarThumbnails.jobs.size).to eq(0)
        message = JSON.parse(response.body)["errors"]
        expect(message).to contain_exactly(I18n.t("upload.images.size_not_found"))
      end
    end
  end

  describe '#show' do
    let(:site) { "default" }
    let(:sha) { Digest::SHA1.hexdigest("discourse") }
    fab!(:user) { Fabricate(:user) }

    def upload_file(file, folder = "images")
      fake_logo = Rack::Test::UploadedFile.new(file_from_fixtures(file, folder))
      SiteSetting.authorized_extensions = "*"
      sign_in(user)

      post "/uploads.json", params: {
        file: fake_logo,
        type: "composer",
      }
      url = JSON.parse(response.body)["url"]
      upload = Upload.where(url: url).first
      upload
    end

    context "when using external storage" do
      before do
        @upload = upload_file("small.pdf", "pdf")
        SiteSetting.enable_s3_uploads = true
        SiteSetting.s3_upload_bucket = "s3-upload-bucket"
        SiteSetting.s3_access_key_id = "s3-access-key-id"
        SiteSetting.s3_secret_access_key = "s3-secret-access-key"
        SiteSetting.s3_region = 'us-west-1'

        store = FileStore::S3Store.new
        s3_helper = store.instance_variable_get(:@s3_helper)
        client = Aws::S3::Client.new(stub_responses: true)
        s3_helper.stubs(:s3_client).returns(client)
        Discourse.stubs(:store).returns(store)
      end

      it "returns 404" do
        @upload.update_column(:url, "//bucket.s3.amazonaws.com/#{@upload.url}")
        get "/uploads/#{site}/#{@upload.sha1}.#{@upload.extension}"
        expect(response.response_code).to eq(404)
      end

      it "returns upload if url not migrated" do
        get "/uploads/#{site}/#{@upload.sha1}.#{@upload.extension}"
        expect(response.status).to eq(200)
      end

      it "redirects to presigned URL for private uploads" do
        SiteSetting.prevent_anons_from_downloading_files = true
        @upload.update_column(:url, "//bucket.s3.amazonaws.com/#{@upload.url}")

        get "/uploads/#{site}/#{@upload.sha1}.#{@upload.extension}"

        expect(response.response_code).to eq(302)
        expect(response.redirect_url).to match(/amazonaws/)
        expect(response.redirect_url).to match(/Amz-Credential/)
      end

      it "does not redirect to presigned S3 URL for private uploads for anons" do
        SiteSetting.prevent_anons_from_downloading_files = true
        @upload.update_column(:url, "//bucket.s3.amazonaws.com/#{@upload.url}")

        delete "/session/#{user.username}.json" # sign out
        get "/uploads/#{site}/#{@upload.sha1}.#{@upload.extension}"

        expect(response.status).to eq(404)
      end
    end

    it "returns 404 when the upload doesn't exist" do
      get "/uploads/#{site}/#{sha}.pdf"
      expect(response.status).to eq(404)
    end

    it "returns 404 when the path is nil" do
      upload = upload_file("logo.png")
      upload.update_column(:url, "invalid-url")

      get "/uploads/#{site}/#{upload.sha1}.#{upload.extension}"
      expect(response.status).to eq(404)
    end

    it 'uses send_file' do
      upload = upload_file("logo.png")
      get "/uploads/#{site}/#{upload.sha1}.#{upload.extension}"
      expect(response.status).to eq(200)

      # rails 6 adds UTF-8 filename to disposition
      expect(response.headers["Content-Disposition"]).to include("attachment; filename=\"logo.png\"")
    end

    it "handles image without extension" do
      SiteSetting.authorized_extensions = "*"
      upload = upload_file("image_no_extension")

      get "/uploads/#{site}/#{upload.sha1}.json"
      expect(response.status).to eq(200)
      expect(response.headers["Content-Disposition"]).to include("attachment; filename=\"image_no_extension.png\"")
    end

    it "handles file without extension" do
      SiteSetting.authorized_extensions = "*"
      upload = upload_file("not_an_image")

      get "/uploads/#{site}/#{upload.sha1}.json"
      expect(response.status).to eq(200)
      expect(response.headers["Content-Disposition"]).to include("attachment; filename=\"not_an_image\"")
    end

    context "prevent anons from downloading files" do
      it "returns 404 when an anonymous user tries to download a file" do
        upload = upload_file("small.pdf", "pdf")
        delete "/session/#{user.username}.json" # upload a file, then sign out

        SiteSetting.prevent_anons_from_downloading_files = true

        get "/uploads/#{site}/#{upload.sha1}.#{upload.extension}"
        expect(response.status).to eq(404)
      end
    end
  end

  describe '#lookup_urls' do
    it 'can look up long urls' do
      sign_in(Fabricate(:user))
      upload = Fabricate(:upload)

      post "/uploads/lookup-urls.json", params: { short_urls: [upload.short_url] }
      expect(response.status).to eq(200)

      result = JSON.parse(response.body)
      expect(result[0]["url"]).to eq(upload.url)
    end
  end

  describe '#metadata' do
    fab!(:upload) { Fabricate(:upload) }

    describe 'when url is missing' do
      it 'should return the right response' do
        post "/uploads/lookup-metadata.json"

        expect(response.status).to eq(403)
      end
    end

    describe 'when not signed in' do
      it 'should return the right response' do
        post "/uploads/lookup-metadata.json", params: { url: upload.url }

        expect(response.status).to eq(403)
      end
    end

    describe 'when signed in' do
      before do
        sign_in(Fabricate(:user))
      end

      describe 'when url is invalid' do
        it 'should return the right response' do
          post "/uploads/lookup-metadata.json", params: { url: 'abc' }

          expect(response.status).to eq(404)
        end
      end

      it "should return the right response" do
        post "/uploads/lookup-metadata.json", params: { url: upload.url }

        expect(response.status).to eq(200)

        result = JSON.parse(response.body)

        expect(result["original_filename"]).to eq(upload.original_filename)
        expect(result["width"]).to eq(upload.width)
        expect(result["height"]).to eq(upload.height)
        expect(result["human_filesize"]).to eq(upload.human_filesize)
      end
    end
  end
end
