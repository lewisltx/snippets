import datetime
import os
import shutil
import subprocess
import time

video_path = 'd:\\'
# video_date = time.strftime('%Y-%m-%d', time.localtime(time.time() - 24*60*60))
video_date = '2023-04-24'
output_file = video_date + '.m4a'
ffmpeg_bin = r'..\..\Documents\Programs\ffmpeg\bin\ffmpeg'


def extract_audio_files():
    os.makedirs(video_date)
    files = os.listdir(video_path)
    start_dt = datetime.datetime.strptime(video_date + ' 23:00:00', '%Y-%m-%d %H:%M:%S')
    start_time = start_dt.timestamp()
    end_time = start_time + (3600 * 8)
    for file in files:
        mtime = os.path.getmtime(os.path.join(video_path, file))
        if start_time <= mtime <= end_time:
            if file.endswith('.mp4'):
                ret = subprocess.call([ffmpeg_bin, '-i', os.path.join(video_path, file), '-vn', '-c:a', 'copy',
                                       '-loglevel', 'quiet', os.path.join(video_date, file.replace('.mp4', '.m4a'))])
                if ret != 0:
                    print(f"extract audio error：{file}")
                    break
    write_concat_file()


# def get_command(video_files):
#     command = [ffmpeg_bin, '-threads', '4']
#     for filename in video_files:
#         command += ['-i', os.path.join(video_path, filename)]
#     command += ['-filter_complex']
#     concat_complex = ''
#     for i in range(0, len(video_files)):
#         concat_complex += '[{}:a:0] '.format(i)
#     command += [concat_complex + 'concat=n={}:v=0:a=1 [out]'.format(len(video_files))]
#     command += ['-map', '[out]', '-c:a', 'aac', '-b:a', '128k', output_file]
#     return command


def write_concat_file():
    files = os.listdir(video_date)
    with open('concat.txt', 'w') as concat_file:
        for file in files:
            concat_file.write('file ' + os.path.join(video_date, file).replace('\\', '/') + '\n')


if __name__ == "__main__":
    extract_audio_files()
    ret = subprocess.call([ffmpeg_bin, '-f', 'concat', '-safe', '0', '-i', 'concat.txt', '-c', 'copy', output_file])
    if ret == 0:
        shutil.rmtree(video_date)
